import Foundation
import Combine
import UserNotifications
import AVFoundation

/// Drives one meeting from the record button to finished notes.
///
/// Two tiers run off the same captured audio. While recording, buffers are fanned
/// out to a per-source file writer and to on-device live captions. After
/// recording, the files are mixed and sent through the diarized transcription
/// pass — one paid call per meeting — and then note generation. The audio is kept
/// until notes exist, so any failure along the way is retryable rather than
/// costing the user the meeting.
///
/// Main-actor isolated because it publishes the recording UI's state. The audio
/// path deliberately does not run here: it lives in `CaptureBufferRouter`, which
/// cannot see this type's state.
@MainActor
final class RecordingCoordinator: ObservableObject {
    typealias LiveTranscriptionFactory = @MainActor () -> LiveTranscriptionServiceProtocol
    typealias SessionRecorderFactory =
        @MainActor (URL, AudioSource, Double) throws -> SessionAudioWriting

    @Published private(set) var state: RecordingState = .idle
    /// Confirmed live captions plus at most one provisional row per source while
    /// recording; the diarized transcript once one exists.
    @Published private(set) var visibleLiveTranscript: [TranscriptChunk] = []
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var systemAudioAvailable = true
    /// False when the system echo canceller could not be started. This only
    /// costs anything while system audio is captured too: the far end then
    /// bleeds from the speakers into the microphone track *and* arrives on its
    /// own track, so the mix contains it twice and it is transcribed and billed
    /// twice. With no system track there is only ever one copy, which is why the
    /// recording view shows this warning only when system audio is available.
    @Published private(set) var echoCancellationEnabled = true
    /// Non-nil when on-device captions are degraded or downloading. The recording
    /// and the final transcript are unaffected.
    @Published private(set) var liveCaptionNotice: String?
    /// Non-nil when the last recording was ended by something other than the
    /// user. Shown as a banner over the detail column until dismissed, because a
    /// user who returns to the app after the fact has no other way to learn why
    /// the recording stopped. Lives only as long as the app session; the
    /// accompanying system notification is what reaches a user who is not
    /// looking at the app.
    @Published private(set) var recordingInterruptedNotice: String?
    @Published private(set) var currentMeetingId: UUID?

    private let audioCapture: AudioCaptureServiceProtocol
    private let makeLiveTranscription: LiveTranscriptionFactory
    private let makeSessionRecorder: SessionRecorderFactory
    private let finalTranscription: FinalTranscriptionServiceProtocol
    private let noteGeneration: NoteGenerationServiceProtocol
    private let store: MeetingStoreProtocol
    private let audioRootDirectory: URL

    private var captions = LiveCaptionAggregator()
    private var liveTranscription: LiveTranscriptionServiceProtocol?
    private var recorders: [AudioSource: SessionAudioWriting] = [:]
    private var bufferCancellable: AnyCancellable?
    private var levelCancellable: AnyCancellable?
    private var systemAudioCancellable: AnyCancellable?
    private var microphoneCancellable: AnyCancellable?
    private var prepareTask: Task<Void, Never>?
    private var liveEventTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?
    private var isStarting = false
    private var isProcessing = false

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    init(
        audioCapture: AudioCaptureServiceProtocol,
        makeLiveTranscription: @escaping LiveTranscriptionFactory,
        finalTranscription: FinalTranscriptionServiceProtocol,
        noteGeneration: NoteGenerationServiceProtocol,
        store: MeetingStoreProtocol,
        audioRootDirectory: URL = MeetingStore.defaultAudioDirectory,
        makeSessionRecorder: @escaping SessionRecorderFactory = { directory, source, sampleRate in
            try SessionRecorder(directory: directory, source: source, sampleRate: sampleRate)
        }
    ) {
        self.audioCapture = audioCapture
        self.makeLiveTranscription = makeLiveTranscription
        self.finalTranscription = finalTranscription
        self.noteGeneration = noteGeneration
        self.store = store
        self.audioRootDirectory = audioRootDirectory
        self.makeSessionRecorder = makeSessionRecorder
    }

    func resetToIdle() {
        state = .idle
        recordingInterruptedNotice = nil
    }

    /// Clears the interruption banner without touching `state`, which may still
    /// be mid-pipeline: the interruption stopped the recording, and processing of
    /// what was captured carries on after the user has read the notice.
    func dismissRecordingInterruptedNotice() {
        recordingInterruptedNotice = nil
    }

    // MARK: - Recording

    func startRecording() async throws {
        // Claimed before the first suspension, not after. startCapture() can take
        // seconds waiting on a permission prompt, and the state stays .idle for
        // all of it, so the menu item that gates on .idle is still live. A second
        // start getting through would overwrite recorders, subscriptions and
        // tasks, orphaning the first recording's unfinalized audio files.
        guard !isStarting, recordingStart == nil else {
            throw CoordinatorError.alreadyRecording
        }
        isStarting = true
        defer { isStarting = false }

        captions = LiveCaptionAggregator()
        visibleLiveTranscript = []
        liveCaptionNotice = nil
        recordingInterruptedNotice = nil

        try await audioCapture.startCapture()
        guard audioCapture.isCapturingMicrophone else {
            await audioCapture.stopCapture()
            throw CaptureAvailabilityError.microphoneUnavailable
        }
        systemAudioAvailable = audioCapture.isCapturingSystemAudio
        echoCancellationEnabled = audioCapture.isEchoCancellationEnabled

        let id = UUID()
        let audioDirectory = audioRootDirectory.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(
                at: audioDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            await audioCapture.stopCapture()
            throw error
        }

        for source in AudioSource.allCases {
            // A source that cannot be written still gets live captions, and the
            // other source's recording is still worth having.
            recorders[source] = try? makeSessionRecorder(
                audioDirectory,
                source,
                audioCapture.captureFormat.sampleRate
            )
        }

        subscribeToAudioPath(routingTo: startLiveTranscription())

        let meeting = Meeting(
            id: id,
            title: "Meeting - \(Self.titleFormatter.string(from: Date()))",
            date: Date(),
            durationSeconds: 0,
            transcript: [],
            notes: nil,
            notesGenerationError: nil,
            audioDirectory: audioDirectory
        )
        store.save(meeting)
        currentMeetingId = id
        recordingStart = Date()
        state = .recording(elapsed: 0)
        startElapsedTimer()
        watchCaptureAvailability()
    }

    /// Starts consuming caption events and kicks off `prepare` without waiting
    /// for it: the first run installs a ~300 MB speech model, and the user
    /// pressed Record, not Download. Buffers that arrive before `prepare`
    /// finishes reach an empty analyzer registry and are dropped, which costs
    /// only captions — the diarized pass reads the recorded files, not the
    /// analyzers.
    private func startLiveTranscription() -> LiveTranscriptionServiceProtocol {
        let service = makeLiveTranscription()
        liveTranscription = service

        liveEventTask = Task { [weak self] in
            for await event in service.events {
                self?.handle(event)
            }
        }
        let sources = AudioSource.allCases
        let locale = Locale(identifier: ModelSettings.shared.effectiveTranscriptionLocaleIdentifier)
        prepareTask = Task { await service.prepare(sources: sources, locale: locale) }
        return service
    }

    private func subscribeToAudioPath(routingTo liveTranscription: LiveTranscriptionServiceProtocol) {
        // Built here, after the recorders and the live service exist, so no
        // buffer can arrive before there is somewhere to put it. The router holds
        // everything the audio path needs, which is what keeps this closure from
        // being able to touch main-actor state.
        let router = CaptureBufferRouter(
            recorders: recorders,
            liveTranscription: liveTranscription
        )
        bufferCancellable = audioCapture.bufferPublisher.sink { tagged in
            router.route(tagged)
        }

        // Throttled rather than hopped per value: levels arrive with every
        // buffer, 50–100 times a second per source, and dispatching each one to
        // the main queue would turn UI congestion into a cost the capture
        // threads pay.
        levelCancellable = audioCapture.audioLevelPublisher
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] level in self?.audioLevel = level }
    }

    /// Armed once there is a recording to act on, because losing the microphone
    /// ends it.
    ///
    /// Both publishers deliver changes on the main queue and the replayed value
    /// on the subscribing thread; subscribing from the main actor covers both, so
    /// neither needs a `receive(on:)` hop.
    private func watchCaptureAvailability() {
        systemAudioCancellable = audioCapture.systemAudioAvailabilityPublisher
            .sink { [weak self] available in self?.systemAudioAvailable = available }

        // The replayed value is not a reliable "microphone is up" signal: the
        // getter flips inside `startCapture()` while the publisher's send is
        // dispatched to the main queue, so this subscription can still be
        // replayed the pre-start `false`. Waiting for the first affirmative
        // value is what stops that from aborting every recording.
        microphoneCancellable = audioCapture.microphoneAvailabilityPublisher
            .drop(while: { !$0 })
            .filter { !$0 }
            .sink { [weak self] _ in self?.handleMicrophoneLoss() }
    }

    private func startElapsedTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.state = .recording(elapsed: Date().timeIntervalSince(start))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func handle(_ event: LiveTranscriptionEvent) {
        let change = captions.apply(event)
        if change.rowsChanged { visibleLiveTranscript = captions.visibleRows }
        if change.noticeChanged { liveCaptionNotice = captions.notice }
    }

    /// The capture layer restarts the engine itself on a device change and only
    /// reports unavailability once that has failed, so there is nothing a retry
    /// from here would do differently. Carrying on would record the far end
    /// alone, and a user who is not watching a menu-bar app would not discover
    /// that until they read the transcript. Ending the recording keeps everything
    /// captured so far and puts it through the normal pipeline; the user can
    /// start a new recording once the device settles.
    private func handleMicrophoneLoss() {
        guard currentMeetingId != nil else { return }
        microphoneCancellable?.cancel()
        microphoneCancellable = nil

        recordingInterruptedNotice = "Recording stopped because the microphone became "
            + "unavailable, so your voice was no longer being captured. Everything recorded "
            + "up to that point was kept."
        sendNotification(
            title: "Recording stopped",
            body: "The microphone became unavailable. Notability is processing what it captured."
        )
        Task { await stopRecording() }
    }

    // MARK: - Stopping

    func stopRecording() async {
        guard let id = currentMeetingId else { return }

        // Dropped first so a microphone-loss notification cannot re-enter this
        // while it is unwinding.
        microphoneCancellable?.cancel()
        microphoneCancellable = nil
        systemAudioCancellable?.cancel()
        systemAudioCancellable = nil
        levelCancellable?.cancel()
        levelCancellable = nil
        audioLevel = 0
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        currentMeetingId = nil
        recordingStart = nil

        // `stopCapture()` closes the relay under the same lock the relay
        // publishes from, so when it returns no `route` call is in progress and
        // no further one can start. Only after that is it safe to finish the
        // consumers the router feeds.
        await audioCapture.stopCapture()
        bufferCancellable?.cancel()
        bufferCancellable = nil

        await finishLiveTranscription()

        for recorder in recorders.values { recorder.finish() }
        // Readable only now: `finish()` drains the writer's own queue, so this is
        // no longer racing the thread that would set it.
        let writeFailure = recorders.values.compactMap(\.writeError).first
        let trackURLs = AudioSource.allCases.compactMap { recorders[$0]?.url }
        recorders.removeAll()

        // Gone means the user deleted the meeting while it was being recorded.
        // There is nothing left to process, and leaving `.recording` behind would
        // strand the UI on a recording screen with no recording.
        guard var meeting = store.fetch(id: id) else {
            state = .idle
            return
        }
        meeting.durationSeconds = duration
        store.save(meeting)

        // A failed write means the file on disk is truncated. Transcribing it
        // automatically would bill for, and hand back, a silently incomplete
        // transcript. The audio is kept, so Retry will process whatever was
        // captured if the user decides that is worth paying for.
        if let writeFailure {
            return fail(
                meeting: meeting,
                transcriptionError: "The recording is incomplete — saving audio failed "
                    + "partway through (\(writeFailure.localizedDescription)). "
                    + "Your audio has been kept."
            )
        }

        await process(meetingId: id, trackURLs: trackURLs)
    }

    /// Ends the live caption tier.
    ///
    /// `prepare` may still be installing assets. It is cancelled and then
    /// `finish()` runs, which is safe to overlap it: `finish()` sets the flag the
    /// service checks at each of `prepare`'s own checkpoints, so a late `prepare`
    /// cannot register an analyzer. This deliberately does not wait for the
    /// install itself, which would make Stop take as long as a 300 MB download.
    ///
    /// Draining the event task is what makes the caption rows complete when this
    /// returns: `finish()` closes the event stream, so the loop consumes whatever
    /// is still buffered and ends.
    private func finishLiveTranscription() async {
        guard let service = liveTranscription else { return }
        liveTranscription = nil

        prepareTask?.cancel()
        prepareTask = nil

        await service.finish()
        await liveEventTask?.value
        liveEventTask = nil
    }

    // MARK: - Post-processing

    /// Re-runs whatever is left of the pipeline for a meeting whose audio was
    /// kept. Does nothing for a meeting that already has notes, because its audio
    /// has been deleted.
    @discardableResult
    func retryProcessing(meetingId: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self,
                  let meeting = self.store.fetch(id: meetingId),
                  let directory = meeting.audioDirectory else { return }
            let tracks = AudioSource.allCases
                .map { directory.appendingPathComponent("\($0.fileBaseName).m4a") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            await self.process(meetingId: meetingId, trackURLs: tracks)
        }
    }

    private func process(meetingId: UUID, trackURLs: [URL]) async {
        guard !isProcessing,
              var meeting = store.fetch(id: meetingId),
              let directory = meeting.audioDirectory else { return }
        isProcessing = true
        defer { isProcessing = false }

        meeting.transcriptionError = nil
        meeting.notesGenerationError = nil
        store.save(meeting)

        // The diarized pass is the one paid call per meeting, so a non-empty
        // transcript means it already succeeded and must not be bought again.
        // Live captions are never written here, which is what keeps that test
        // unambiguous.
        if meeting.transcript.isEmpty {
            state = .transcribing(meetingId: meeting.id)
            let existingTracks = trackURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existingTracks.isEmpty else {
                return fail(meeting: meeting, transcriptionError: "No audio was captured.")
            }
            do {
                let transcription = try await transcribe(tracks: existingTracks, in: directory)
                guard !transcription.chunks.isEmpty else {
                    return fail(
                        meeting: meeting,
                        transcriptionError: "The recording contained no recognisable speech."
                    )
                }
                meeting.transcript = transcription.chunks
                meeting.billedSeconds = transcription.billedSeconds
                store.save(meeting)
            } catch {
                return fail(meeting: meeting, transcriptionError: error.localizedDescription)
            }
        }
        visibleLiveTranscript = meeting.transcript

        state = .generatingNotes(meetingId: meeting.id)
        do {
            meeting.notes = try await noteGeneration.generateNotes(transcript: meeting.transcript)
            meeting.notesGenerationError = nil
            store.save(meeting)
        } catch {
            meeting.notesGenerationError = error.localizedDescription
            store.save(meeting)
            state = .failed(error.localizedDescription)
            sendNotification(
                title: "Processing failed",
                body: "Your recording was saved. Open Notability to retry."
            )
            return
        }

        // The audio has served its purpose only once notes exist. Deleting it
        // any earlier would make a failure unrecoverable without re-recording
        // the meeting.
        try? FileManager.default.removeItem(at: directory)
        meeting.audioDirectory = nil
        store.save(meeting)

        state = .done(meetingId: meetingId)
        sendNotification(
            title: "Meeting notes ready",
            body: "Your meeting notes have been generated."
        )
    }

    private func transcribe(tracks: [URL], in directory: URL) async throws -> DiarizedTranscription {
        let mixedURL = directory.appendingPathComponent("mixed.m4a")
        // Mixing and reference extraction decode and re-encode the whole
        // recording. Off the main actor, because on a two-hour meeting that is
        // long enough to freeze the window.
        try await Task.detached(priority: .userInitiated) {
            try AudioMixer.mix(tracks: tracks, to: mixedURL)
        }.value

        let micURL = directory.appendingPathComponent("\(AudioSource.microphone.fileBaseName).m4a")
        let systemURL = directory
            .appendingPathComponent("\(AudioSource.systemAudio.fileBaseName).m4a")
        let hasSystemTrack = FileManager.default.fileExists(atPath: systemURL.path)
        // A missing reference costs only speaker naming: the local user's turns
        // still get separated, they just get a letter instead of a label.
        let reference = await Task.detached(priority: .userInitiated) {
            try? SpeakerReferenceExtractor.extract(
                micURL: micURL,
                systemURL: hasSystemTrack ? systemURL : nil
            )
        }.value

        let language = ModelSettings.shared.transcriptionLanguage
        return try await finalTranscription.transcribe(
            audioURL: mixedURL,
            speakerReference: reference,
            language: language.isEmpty ? nil : language
        )
    }

    private func fail(meeting: Meeting, transcriptionError: String) {
        var updated = meeting
        updated.transcriptionError = transcriptionError
        store.save(updated)
        state = .failed(transcriptionError)
        sendNotification(
            title: "Processing failed",
            body: "Your recording was saved. Open Notability to retry."
        )
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private enum CoordinatorError: Error, LocalizedError {
        case alreadyRecording

        var errorDescription: String? {
            "A recording is already in progress."
        }
    }

    private enum CaptureAvailabilityError: Error, LocalizedError {
        case microphoneUnavailable

        var errorDescription: String? {
            "Microphone capture is required so your voice is included in the transcript. "
                + "Check your input device and Microphone privacy settings, then try again."
        }
    }
}
