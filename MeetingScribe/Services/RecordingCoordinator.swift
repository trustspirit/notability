import Foundation
import Combine
import UserNotifications

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published var liveTranscript: [TranscriptChunk] = []
    @Published private(set) var livePartialTranscript: TranscriptChunk?
    @Published private(set) var visibleLiveTranscript: [TranscriptChunk] = []
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var systemAudioAvailable: Bool = true
    @Published private(set) var pendingTranscriptionCount = 0
    private var livePartialTranscriptToken: UUID?
    private var rawTranscriptChunks: [TranscriptChunk] = []

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcription: TranscriptionServiceProtocol
    private let noteGeneration: NoteGenerationServiceProtocol
    private let store: MeetingStoreProtocol
    private var chunkHandlingTask: Task<Void, Never>?
    @Published private(set) var currentMeetingId: UUID?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?
    private var levelCancellable: AnyCancellable?
    // Last ~200 chars of transcript sent as Whisper prompt to preserve context across chunk boundaries.
    private var lastTranscriptContext: String = ""

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static let transcriptionFailurePrefix = "[transcription failed"
    private static let maxMergeTimestampGap: TimeInterval = 8.0

    init(
        audioCapture: AudioCaptureServiceProtocol,
        transcription: TranscriptionServiceProtocol,
        noteGeneration: NoteGenerationServiceProtocol,
        store: MeetingStoreProtocol
    ) {
        self.audioCapture = audioCapture
        self.transcription = transcription
        self.noteGeneration = noteGeneration
        self.store = store
    }

    func resetToIdle() {
        state = .idle
    }

    func startRecording() async throws {
        let id = UUID()
        rawTranscriptChunks = []
        liveTranscript = []
        livePartialTranscript = nil
        visibleLiveTranscript = []
        livePartialTranscriptToken = nil
        pendingTranscriptionCount = 0
        lastTranscriptContext = ""
        chunkHandlingTask?.cancel()

        // Start capture first — only save meeting if it actually succeeds.
        try await audioCapture.startCapture()
        systemAudioAvailable = (audioCapture as? AudioCaptureService)?.isCapturingSystemAudio ?? true

        let title = "Meeting - \(Self.titleFormatter.string(from: Date()))"
        let meeting = Meeting(id: id, title: title, date: Date(), durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
        store.save(meeting)
        currentMeetingId = id
        recordingStart = Date()
        state = .recording(elapsed: 0)

        levelCancellable = audioCapture.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.audioLevel = level }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.state = .recording(elapsed: Date().timeIntervalSince(start))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer

        // Consume chunks concurrently. The group exits only after the publisher
        // completes (signalled by stopCapture() → subject.send(completion:)),
        // guaranteeing all in-flight transcriptions finish before stopRecording
        // proceeds past `await chunkHandlingTask?.value`.
        let publisher = audioCapture.chunkPublisher
        chunkHandlingTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for await chunk in publisher.values {
                    guard let self else { break }
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.handleChunk(chunk)
                    }
                }
            }
        }
    }

    func stopRecording() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        levelCancellable?.cancel()
        levelCancellable = nil
        audioLevel = 0

        // stopCapture() flushes the final partial chunk (synchronously) then
        // sends .finished on the publisher, causing the for-await loop in
        // chunkHandlingTask to exit after all in-flight Tasks complete.
        await audioCapture.stopCapture()
        await chunkHandlingTask?.value
        chunkHandlingTask = nil

        guard let id = currentMeetingId else { return }
        defer {
            currentMeetingId = nil
            recordingStart = nil
        }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0

        liveTranscript = Self.mergedTranscriptRows(from: rawTranscriptChunks)
        visibleLiveTranscript = liveTranscript
        var meeting = store.fetch(id: id) ?? Meeting(id: id, title: "Meeting", date: Date(), durationSeconds: duration, transcript: liveTranscript, notes: nil, notesGenerationError: nil)
        meeting.durationSeconds = duration
        meeting.transcript = liveTranscript
        store.save(meeting)

        state = .processing

        do {
            let validTranscript = liveTranscript.filter { !Self.isTranscriptionFailure($0.text) }
            guard !validTranscript.isEmpty else {
                let msg = "No audio was captured or all transcription attempts failed."
                meeting.notesGenerationError = msg
                store.save(meeting)
                state = .failed(msg)
                sendFailureNotification()
                return
            }
            let notes = try await noteGeneration.generateNotes(transcript: validTranscript)
            meeting.notes = notes
            store.save(meeting)
            state = .done(meetingId: id)
            sendCompletionNotification()
        } catch {
            meeting.notesGenerationError = error.localizedDescription
            store.save(meeting)
            state = .failed(error.localizedDescription)
            sendFailureNotification()
        }
    }

    private func handleChunk(_ chunk: (url: URL, timestamp: TimeInterval)) async {
        pendingTranscriptionCount += 1
        let partialToken = UUID()
        defer {
            pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
            try? FileManager.default.removeItem(at: chunk.url)
        }
        do {
            let ctx = lastTranscriptContext
            let transcriptChunk = try await transcription.transcribe(
                audioURL: chunk.url,
                timestamp: chunk.timestamp,
                prompt: ctx.isEmpty ? nil : ctx,
                onPartialTranscript: { [weak self] partial in
                    await self?.updateLivePartialTranscript(partial, timestamp: chunk.timestamp, token: partialToken)
                }
            )
            guard !transcriptChunk.text.isEmpty, Self.isMeaningfulTranscript(transcriptChunk.text) else {
                clearLivePartialTranscript(token: partialToken)
                return
            }
            clearLivePartialTranscript(token: partialToken)
            addTranscriptChunk(transcriptChunk)
            // Keep last ~200 chars as context for the next chunk to prevent sentence cutting.
            let allText = liveTranscript
                .filter { !Self.isTranscriptionFailure($0.text) && Self.isMeaningfulTranscript($0.text) }
                .map(\.text)
                .joined(separator: " ")
            lastTranscriptContext = String(allText.suffix(200))
        } catch {
            clearLivePartialTranscript(token: partialToken)
            let errorChunk = TranscriptChunk(timestamp: chunk.timestamp, text: "[transcription failed: \(error.localizedDescription)]")
            addTranscriptChunk(errorChunk)
        }
    }

    private func addTranscriptChunk(_ chunk: TranscriptChunk) {
        rawTranscriptChunks.append(chunk)
        liveTranscript = Self.mergedTranscriptRows(from: rawTranscriptChunks)
        updateVisibleLiveTranscript()
    }

    private func updateLivePartialTranscript(_ text: String, timestamp: TimeInterval, token: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isMeaningfulTranscript(trimmed) else { return }
        livePartialTranscriptToken = token
        livePartialTranscript = TranscriptChunk(timestamp: timestamp, text: trimmed)
        updateVisibleLiveTranscript()
    }

    private func clearLivePartialTranscript(token: UUID) {
        if livePartialTranscriptToken == token {
            livePartialTranscriptToken = nil
            livePartialTranscript = nil
            updateVisibleLiveTranscript()
        }
    }

    private func updateVisibleLiveTranscript() {
        var rows = rawTranscriptChunks
        if let livePartialTranscript {
            rows.append(livePartialTranscript)
        }
        visibleLiveTranscript = Self.mergedTranscriptRows(from: rows)
    }

    private static func isTranscriptionFailure(_ text: String) -> Bool {
        text.hasPrefix(transcriptionFailurePrefix)
    }

    private static func mergedTranscriptRows(from chunks: [TranscriptChunk]) -> [TranscriptChunk] {
        let sorted = chunks.sorted { $0.timestamp < $1.timestamp }
        var merged: [TranscriptChunk] = []
        var lastMergedSourceTimestamp: TimeInterval?

        for chunk in sorted {
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let row = TranscriptChunk(timestamp: chunk.timestamp, text: text)

            guard
                let last = merged.last,
                let lastSourceTimestamp = lastMergedSourceTimestamp,
                !isTranscriptionFailure(last.text),
                !isTranscriptionFailure(text),
                chunk.timestamp - lastSourceTimestamp <= maxMergeTimestampGap,
                shouldMergeWithPreviousSentence(last.text)
            else {
                merged.append(row)
                lastMergedSourceTimestamp = chunk.timestamp
                continue
            }

            merged[merged.count - 1] = TranscriptChunk(
                timestamp: last.timestamp,
                text: joinedTranscriptText(last.text, text)
            )
            lastMergedSourceTimestamp = chunk.timestamp
        }

        return merged
    }

    private static func shouldMergeWithPreviousSentence(_ text: String) -> Bool {
        !endsWithSentenceTerminator(text)
    }

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        let closingCharacters = Set<Character>(["\"", "'", "”", "’", ")", "]", "}"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastMeaningful = trimmed.reversed().first(where: { !closingCharacters.contains($0) }) else {
            return false
        }
        return [".", "?", "!", "。", "！", "？"].contains(lastMeaningful)
    }

    private static func joinedTranscriptText(_ left: String, _ right: String) -> String {
        let trimmedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else { return trimmedRight }
        guard !trimmedRight.isEmpty else { return trimmedLeft }
        return "\(trimmedLeft) \(trimmedRight)"
    }

    private static func isMeaningfulTranscript(_ text: String) -> Bool {
        let normalized = text
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !normalized.isEmpty else { return false }
        if normalized.allSatisfy({ $0 == "아" }) {
            return false
        }
        return true
    }

    private func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting notes ready"
        content.body = "Your meeting notes have been generated."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendFailureNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Note generation failed"
        content.body = "Your meeting was saved but notes could not be generated."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
