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

    /// The mode the current — or most recent — recording was started in.
    ///
    /// Read with `systemAudioAvailable` rather than instead of it: together they
    /// separate "the user asked for microphone only" from "system audio was
    /// wanted and could not be had", which are the same state to everything
    /// downstream and opposite states to the person being shown a warning.
    /// Outlives the recording because processing needs it too; see `transcribe`.
    @Published private(set) var recordingMode: RecordingMode = .microphoneAndSystem
    /// False when the system echo canceller could not be started. This only
    /// costs anything while system audio is captured too, and only on speakers:
    /// the far end then reaches the microphone track *and* arrives on its own
    /// track, so the mix carries it twice. Cost is unaffected — the mix is billed by
    /// its length, which is the wall clock either way — but the duplicate can be
    /// transcribed twice and attributed to the local speaker, whose voice the
    /// speaker reference has already named. With no system track there is only
    /// ever one copy, which is why the recording view shows this warning only
    /// when system audio is available.
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
        },
        teardownDeadline: Duration = .seconds(3)
    ) {
        self.audioCapture = audioCapture
        self.makeLiveTranscription = makeLiveTranscription
        self.finalTranscription = finalTranscription
        self.noteGeneration = noteGeneration
        self.store = store
        self.audioRootDirectory = audioRootDirectory
        self.makeSessionRecorder = makeSessionRecorder
        self.teardownDeadline = teardownDeadline
    }

    /// How long the capture sessions are given to shut down before the recording
    /// is finished without them. Injected so a test does not have to wait it out.
    private let teardownDeadline: Duration

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

    func startRecording(mode: RecordingMode = .microphoneAndSystem) async throws {
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

        recordingMode = mode
        try await audioCapture.startCapture(mode: mode)
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

    /// Ends the recording and puts what was captured through the pipeline.
    func stopRecording() async {
        guard let ended = await endRecording() else { return }

        // A failed write means the file on disk is truncated. Transcribing it
        // automatically would bill for, and hand back, a silently incomplete
        // transcript. The audio is kept, so Retry will process whatever was
        // captured if the user decides that is worth paying for.
        if let writeFailure = ended.writeError {
            return fail(
                meetingId: ended.meetingId,
                transcriptionError: ProcessingStatusMessage.incompleteWrite(writeFailure)
            )
        }

        await process(meetingId: ended.meetingId)
    }

    /// Ends the recording, leaves the audio on disk and does not process it.
    ///
    /// This is what quitting mid-recording does. Finishing the writers is what
    /// completes the MPEG-4 containers, and therefore the only thing that makes
    /// the files readable at the next launch; the meeting then records why it has
    /// no notes so nothing downstream has to guess. What it deliberately does
    /// not do is start the paid transcription — the user asked to quit, and the
    /// retention policy already covers processing it later.
    func saveRecordingForLater() async {
        guard let ended = await endRecording() else { return }
        // A write that failed is a failure of a stage that ran, so only the
        // ordinary case counts as the app having stopped the work itself.
        let writeFailure = ended.writeError
        store.update(id: ended.meetingId) {
            $0.transcriptionError = writeFailure.map(ProcessingStatusMessage.incompleteWrite)
                ?? ProcessingStatusMessage.quitDuringRecording
            $0.processingWasInterrupted = writeFailure == nil
        }
        state = .idle
    }

    /// Closes the recording's audio files on the way out of the process.
    ///
    /// `applicationWillTerminate` cannot await, so this does only the part that
    /// has to happen before the process dies: releasing the writers, which
    /// completes the containers. Without it the files hold sample data behind an
    /// unwritten `moov` atom that no decoder will open, which is what used to
    /// leave an interrupted meeting offering a Retry that could never succeed.
    ///
    /// A no-op once either stop path has run, and a no-op when nothing is
    /// recording. It does not describe the meeting's state: the store reads the
    /// files at the next launch and reports what it finds there, which is also
    /// what covers the terminations that never reach this at all.
    func finalizeAudioForTermination() {
        guard let id = currentMeetingId else { return }
        for recorder in recorders.values { recorder.finish() }
        recorders.removeAll()
        if let start = recordingStart {
            store.update(id: id) { $0.durationSeconds = Date().timeIntervalSince(start) }
        }
    }

    private struct EndedRecording {
        let meetingId: UUID
        let writeError: Error?
    }

    /// Tears down the capture path and closes the audio files.
    ///
    /// nil means there is nothing left to act on: either no recording was
    /// running, or the meeting was deleted while it was. In that second case the
    /// audio goes with it — nothing will ever read it again, and it is the one
    /// directory no meeting record is left to point at — and the UI is put back
    /// to idle rather than stranded on a recording screen with no recording.
    private func endRecording() async -> EndedRecording? {
        guard let id = currentMeetingId else { return nil }

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
        recordingStart = nil

        // `stopDelivery()` closes the relay under the same lock the relay
        // publishes from, so when it returns no `route` call is in progress and
        // no further one can start. Only after that is it safe to finish the
        // consumers the router feeds — and it is all that is needed for that,
        // which is why the recording is closed here rather than after the
        // capture sessions have been released.
        audioCapture.stopDelivery()
        bufferCancellable?.cancel()
        bufferCancellable = nil

        for recorder in recorders.values { recorder.finish() }
        // Readable only now: `finish()` drains the writer's own queue, so this is
        // no longer racing the thread that would set it.
        let writeFailure = recorders.values.compactMap(\.writeError).first
        recorders.removeAll()

        // Cleared only once the files are closed, and only from code that cannot
        // suspend before reaching here. `finalizeAudioForTermination()` is the
        // last-chance close for a termination that does not come through this
        // path, and this is what arms it: clearing it any earlier disarmed it
        // for the whole of the teardown below — exactly when a stuck teardown
        // meant it was the only thing left to close the files.
        currentMeetingId = nil

        // Everything the recording promised is on disk by here. What is left is
        // asking ScreenCaptureKit and the speech analyser to let go, and neither
        // promises to answer: a stream that has already died can leave its
        // `stopCapture()` suspended for the life of the process. Waiting on that
        // unbounded is what left the app un-quittable, with a frozen timer in
        // the menu bar and no way to reach it, so it gets a deadline. Missing it
        // costs nothing the user can see: the process is either about to end, or
        // starting a recording again, which stops these sources itself.
        await withDeadline(teardownDeadline) { [self] in
            await audioCapture.finishTeardown()
            await finishLiveTranscription()
        }

        guard store.fetch(id: id) != nil else {
            try? FileManager.default.removeItem(at: audioDirectory(for: id))
            state = .idle
            return nil
        }
        store.update(id: id) { $0.durationSeconds = duration }
        return EndedRecording(meetingId: id, writeError: writeFailure)
    }

    private func audioDirectory(for meetingId: UUID) -> URL {
        audioRootDirectory.appendingPathComponent(meetingId.uuidString)
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

    /// Re-runs whatever is left of the pipeline for a meeting that still has
    /// something to gain from it; see `Meeting.canRetryProcessing`, which is also
    /// what the Retry button is offered on, so this cannot be reached for a
    /// meeting that would only fail the same way again.
    @discardableResult
    func retryProcessing(meetingId: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self,
                  let meeting = self.store.fetch(id: meetingId),
                  meeting.canRetryProcessing else { return }
            await self.process(meetingId: meetingId)
        }
    }

    /// Everything between a finished recording and finished notes.
    ///
    /// Reads the meeting once for the decisions it has to make and writes
    /// through `store.update` from then on, never saving the copy it read. Both
    /// paid stages suspend for minutes — a 600 second timeout, up to five
    /// attempts — and the detail view's title field is on screen throughout, so
    /// a snapshot written back at the end silently undid a rename made in
    /// between.
    private func process(meetingId: UUID) async {
        guard !isProcessing, let meeting = store.fetch(id: meetingId) else { return }
        isProcessing = true
        defer { isProcessing = false }

        store.update(id: meetingId) {
            $0.transcriptionError = nil
            $0.notesGenerationError = nil
            // Whatever stopped the last attempt, this one is running: anything
            // it reports from here is a failure of a stage that ran.
            $0.processingWasInterrupted = false
        }

        // The diarized pass is the one paid call per meeting, so a non-empty
        // transcript means it already succeeded and must not be bought again.
        // Live captions are never written here, which is what keeps that test
        // unambiguous.
        var transcript = meeting.transcript
        if transcript.isEmpty {
            state = .transcribing(meetingId: meetingId)
            guard let chunks = await transcribeRecording(
                meetingId: meetingId,
                directory: meeting.audioDirectory
            ) else { return }
            transcript = chunks
        }
        visibleLiveTranscript = transcript

        state = .generatingNotes(meetingId: meetingId)
        do {
            let notes = try await noteGeneration.generateNotes(transcript: transcript)
            store.update(id: meetingId) {
                $0.notes = notes
                $0.notesGenerationError = nil
            }
        } catch {
            store.update(id: meetingId) { $0.notesGenerationError = error.localizedDescription }
            state = .failed(error.localizedDescription)
            notifyProcessingFailed(meetingId: meetingId)
            return
        }

        // The audio has served its purpose only once notes exist. Deleting it
        // any earlier would make a failure unrecoverable without re-recording
        // the meeting.
        discardAudio(of: meetingId, at: meeting.audioDirectory)

        state = .done(meetingId: meetingId)
        sendNotification(
            title: "Meeting notes ready",
            body: "Your meeting notes have been generated."
        )
    }

    /// Runs the paid pass over the recorded audio and saves what comes back. nil
    /// means it did not happen and the meeting already records why.
    private func transcribeRecording(
        meetingId: UUID,
        directory: URL?
    ) async -> [TranscriptChunk]? {
        guard let directory else {
            fail(meetingId: meetingId, transcriptionError: ProcessingStatusMessage.noAudioCaptured)
            return nil
        }

        let tracks: [URL]
        switch RecordedSessionAudio.inspect(directory: directory) {
        case .usable(let readable):
            tracks = readable
        case .empty:
            fail(meetingId: meetingId, transcriptionError: ProcessingStatusMessage.noAudioCaptured)
            return nil
        case .unreadable:
            // No decoder will ever open these files, so keeping them only holds
            // disk and keeps offering a Retry that cannot work. Dropping the
            // directory is what withdraws that offer.
            discardAudio(of: meetingId, at: directory)
            fail(
                meetingId: meetingId,
                transcriptionError: ProcessingStatusMessage.unreadableAudio,
                // The files were left this way by something that stopped the app
                // mid-recording, which is what the message describes.
                wasInterrupted: true
            )
            return nil
        }

        do {
            let transcription = try await transcribe(tracks: tracks, in: directory)
            guard !transcription.chunks.isEmpty else {
                fail(
                    meetingId: meetingId,
                    transcriptionError: ProcessingStatusMessage.noSpeechRecognised
                )
                return nil
            }
            store.update(id: meetingId) {
                $0.transcript = transcription.chunks
                $0.billedSeconds = transcription.billedSeconds
            }
            return transcription.chunks
        } catch {
            fail(meetingId: meetingId, transcriptionError: error.localizedDescription)
            return nil
        }
    }

    private func discardAudio(of meetingId: UUID, at directory: URL?) {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store.update(id: meetingId) { $0.audioDirectory = nil }
    }

    private func transcribe(tracks: [URL], in directory: URL) async throws -> DiarizedTranscription {
        let mixedURL = directory.appendingPathComponent("mixed.m4a")
        // Mixing and reference extraction decode and re-encode the whole
        // recording. Off the main actor, because on a two-hour meeting that is
        // long enough to freeze the window.
        try await Task.detached(priority: .userInitiated) {
            try AudioMixer.mix(tracks: tracks, to: mixedURL)
        }.value

        let micURL = RecordedSessionAudio.trackURL(for: .microphone, in: directory)
        let systemURL = RecordedSessionAudio.trackURL(for: .systemAudio, in: directory)
        // Membership rather than existence: `tracks` is already filtered to what
        // a decoder can open, and handing the extractor a file that will not is
        // no better than not having one.
        let hasSystemTrack = tracks.contains(systemURL)
        // A missing reference costs only speaker naming: the local user's turns
        // still get separated, they just get a letter instead of a label.
        let mode = recordingMode
        let reference: Data? = Self.shouldExtractSpeakerReference(mode: mode)
            ? await Task.detached(priority: .userInitiated) {
                try? SpeakerReferenceExtractor.extract(
                    micURL: micURL,
                    systemURL: hasSystemTrack ? systemURL : nil
                )
            }.value
            : nil

        let language = ModelSettings.shared.transcriptionLanguage
        return try await finalTranscription.transcribe(
            audioURL: mixedURL,
            speakerReference: reference,
            language: language.isEmpty ? nil : language
        )
    }

    /// Whether the microphone track is trustworthy enough to name a speaker
    /// from.
    ///
    /// `SpeakerReferenceExtractor` identifies the local user as whoever talks
    /// while the system track is silent. With no system track at all that test
    /// passes for anyone, so a recording that never wanted one — an in-person
    /// meeting, several people around one microphone — would label whoever
    /// spoke first as the local user for the entire transcript. An anonymous
    /// letter is a smaller error than a confident wrong name.
    ///
    /// A recording that asked for system audio and did not get it is a different
    /// case and keeps its reference: there was still a far end, it just arrived
    /// through the speakers, so the microphone track is still the local user's.
    nonisolated static func shouldExtractSpeakerReference(mode: RecordingMode) -> Bool {
        mode.capturesSystemAudio
    }

    private func fail(meetingId: UUID, transcriptionError: String, wasInterrupted: Bool = false) {
        store.update(id: meetingId) {
            $0.transcriptionError = transcriptionError
            $0.processingWasInterrupted = wasInterrupted
        }
        state = .failed(transcriptionError)
        notifyProcessingFailed(meetingId: meetingId)
    }

    /// The body has to match what the meeting can actually do next. Telling a
    /// user to retry a meeting whose audio has just been discarded as unreadable
    /// is the same false promise the interrupted-meeting message used to make.
    private func notifyProcessingFailed(meetingId: UUID) {
        let canRetry = store.fetch(id: meetingId)?.canRetryProcessing ?? false
        sendNotification(
            title: "Processing failed",
            body: canRetry
                ? "Your recording was saved. Open Notability to retry."
                : "Open Notability for details."
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
