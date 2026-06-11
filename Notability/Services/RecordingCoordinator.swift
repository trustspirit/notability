import Foundation
import Combine
import UserNotifications

private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { count = limit }

    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.resume()
        } else {
            count += 1
        }
    }
}

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
    // Source of truth for live transcript state. `liveTranscript` is published
    // to the UI as a derived value via didSet, so the chunk text and its
    // merge-window timestamp can never drift apart (would happen if they
    // lived in two separate arrays).
    private var liveTranscriptRows: [LiveTranscriptRow] = [] {
        didSet { liveTranscript = liveTranscriptRows.map(\.chunk) }
    }

    private struct LiveTranscriptRow {
        var chunk: TranscriptChunk
        var lastSourceTimestamp: TimeInterval
    }

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcription: TranscriptionServiceProtocol
    private let transcriptionSemaphore = AsyncSemaphore(limit: 4)
    private let noteGeneration: NoteGenerationServiceProtocol
    private let store: MeetingStoreProtocol
    private var chunkHandlingTask: Task<Void, Never>?
    @Published private(set) var currentMeetingId: UUID?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?
    private var levelCancellable: AnyCancellable?

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static let transcriptionFailurePrefix = "[transcription failed"
    private static let maxMergeTimestampGap: TimeInterval = 8.0
    private typealias TranscriptMergeEntry = (row: TranscriptChunk, lastSourceTimestamp: TimeInterval)

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
        liveTranscriptRows = []
        livePartialTranscript = nil
        visibleLiveTranscript = []
        livePartialTranscriptToken = nil
        pendingTranscriptionCount = 0
        chunkHandlingTask?.cancel()

        // Start capture first — only save meeting if it actually succeeds.
        try await audioCapture.startCapture()
        systemAudioAvailable = audioCapture.isCapturingSystemAudio

        let title = "Meeting - \(Self.titleFormatter.string(from: Date()))"
        let meeting = Meeting(id: id, title: title, date: Date(), durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
        store.save(meeting)
        currentMeetingId = id
        recordingStart = Date()
        state = .recording(elapsed: 0)

        // Audio buffers arrive 50–100 times per second; pushing every sample into
        // SwiftUI saturates the main runloop and eventually corrupts AppKit/SwiftUI
        // render state after several minutes of recording.
        levelCancellable = audioCapture.audioLevelPublisher
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
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

    func retryNoteGeneration(meetingId: UUID) {
        Task {
            guard var meeting = store.fetch(id: meetingId) else { return }
            let validTranscript = meeting.transcript.filter { !Self.isTranscriptionFailure($0.text) }
            guard !validTranscript.isEmpty else { return }
            meeting.notesGenerationError = nil
            meeting.notes = nil
            store.save(meeting)
            do {
                let notes = try await noteGeneration.generateNotes(transcript: validTranscript)
                meeting.notes = notes
                meeting.notesGenerationError = nil
                store.save(meeting)
                sendCompletionNotification()
            } catch {
                meeting.notesGenerationError = error.localizedDescription
                store.save(meeting)
                sendFailureNotification()
            }
        }
    }

    private func handleChunk(_ chunk: AudioChunk) async {
        pendingTranscriptionCount += 1
        let partialToken = UUID()
        defer {
            pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
            try? FileManager.default.removeItem(at: chunk.url)
        }
        // Limit concurrent API calls so a burst of mic+system chunks doesn't
        // saturate the OpenAI rate limit and produce 429-driven transcription gaps.
        await transcriptionSemaphore.wait()
        defer { Task { await self.transcriptionSemaphore.signal() } }
        do {
            // prompt: nil — rolling-transcript prompts caused gpt-4o-transcribe to echo
            // previous content into new chunks. TranscriptionService injects a short
            // static language-anchor prompt instead, which doesn't trigger that echo.
            let transcriptChunk = try await transcription.transcribe(
                audioURL: chunk.url,
                timestamp: chunk.timestamp,
                prompt: nil,
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
        } catch {
            clearLivePartialTranscript(token: partialToken)
            let errorChunk = TranscriptChunk(timestamp: chunk.timestamp, text: "[transcription failed: \(error.localizedDescription)]")
            addTranscriptChunk(errorChunk)
        }
    }

    private func addTranscriptChunk(_ chunk: TranscriptChunk) {
        let merged = Self.mergedTranscriptEntries(
            from: liveTranscriptMergeEntries
                + [(row: chunk, lastSourceTimestamp: chunk.timestamp)]
        )
        liveTranscriptRows = merged.map {
            LiveTranscriptRow(chunk: $0.row, lastSourceTimestamp: $0.lastSourceTimestamp)
        }
        updateVisibleLiveTranscript()
        persistCurrentTranscriptSnapshot()
    }

    private func persistCurrentTranscriptSnapshot() {
        guard let id = currentMeetingId else { return }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        store.persistTranscriptSnapshot(id: id, transcript: liveTranscript, durationSeconds: duration)
    }

    private func updateLivePartialTranscript(_ text: String, timestamp: TimeInterval, token: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isMeaningfulTranscript(trimmed) else { return }
        // Realtime API streams cumulative deltas — many consecutive partials are
        // identical strings. Skip redundant @Published writes to avoid pointless
        // SwiftUI re-layout work on every websocket event.
        if livePartialTranscriptToken == token,
           livePartialTranscript?.text == trimmed,
           livePartialTranscript?.timestamp == timestamp {
            return
        }
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
        // Fast path: no partial means visibleLiveTranscript is exactly liveTranscript,
        // which addTranscriptChunk has already merged. Avoid a second O(N) merge pass
        // on every chunk add.
        guard let partial = livePartialTranscript else {
            visibleLiveTranscript = liveTranscript
            return
        }
        let merged = Self.mergedTranscriptEntries(
            from: liveTranscriptMergeEntries + [(row: partial, lastSourceTimestamp: partial.timestamp)]
        )
        visibleLiveTranscript = merged.map { $0.row }
    }

    private static func isTranscriptionFailure(_ text: String) -> Bool {
        text.hasPrefix(transcriptionFailurePrefix)
    }

    private var liveTranscriptMergeEntries: [TranscriptMergeEntry] {
        liveTranscriptRows.map { (row: $0.chunk, lastSourceTimestamp: $0.lastSourceTimestamp) }
    }

    private static func mergedTranscriptEntries(from entries: [TranscriptMergeEntry]) -> [TranscriptMergeEntry] {
        let sorted = entries.sorted { $0.row.timestamp < $1.row.timestamp }
        var merged: [TranscriptMergeEntry] = []

        for entry in sorted {
            let text = entry.row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let row = TranscriptChunk(timestamp: entry.row.timestamp, text: text)

            if let last = merged.last,
               !isTranscriptionFailure(last.row.text),
               !isTranscriptionFailure(text),
               row.timestamp - last.lastSourceTimestamp <= maxMergeTimestampGap,
               let deduplicated = deduplicatedAdjacentTranscriptText(last.row.text, text) {
                merged[merged.count - 1] = (
                    row: TranscriptChunk(timestamp: last.row.timestamp, text: deduplicated),
                    lastSourceTimestamp: entry.lastSourceTimestamp
                )
                continue
            }

            guard
                let last = merged.last,
                !isTranscriptionFailure(last.row.text),
                !isTranscriptionFailure(text),
                row.timestamp - last.lastSourceTimestamp <= maxMergeTimestampGap,
                shouldMergeWithPreviousSentence(last.row.text)
            else {
                merged.append((row: row, lastSourceTimestamp: entry.lastSourceTimestamp))
                continue
            }

            merged[merged.count - 1] = (
                row: TranscriptChunk(
                    timestamp: last.row.timestamp,
                    text: joinedTranscriptText(last.row.text, text)
                ),
                lastSourceTimestamp: entry.lastSourceTimestamp
            )
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

    private static func deduplicatedAdjacentTranscriptText(_ left: String, _ right: String) -> String? {
        let trimmedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLeft = normalizedForTranscriptComparison(trimmedLeft)
        let normalizedRight = normalizedForTranscriptComparison(trimmedRight)
        let minimumOverlapLength = 4

        guard normalizedLeft.count >= minimumOverlapLength,
              normalizedRight.count >= minimumOverlapLength else {
            return nil
        }

        if normalizedLeft == normalizedRight || normalizedLeft.hasPrefix(normalizedRight) {
            return trimmedLeft
        }
        if normalizedRight.hasPrefix(normalizedLeft) {
            return trimmedRight
        }
        guard let overlapLength = longestSuffixPrefixOverlap(
            left: normalizedLeft,
            right: normalizedRight,
            minimumLength: minimumOverlapLength
        ) else {
            return nil
        }

        let remainder = rightRemainderAfterNormalizedPrefix(trimmedRight, prefixLength: overlapLength)
        guard !remainder.text.isEmpty else { return trimmedLeft }
        let separator = remainder.continuesToken || remainder.text.first?.isPunctuation == true ? "" : " "
        return "\(trimmedLeft)\(separator)\(remainder.text)"
    }

    private static func normalizedForTranscriptComparison(_ text: String) -> String {
        text
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func longestSuffixPrefixOverlap(
        left: String,
        right: String,
        minimumLength: Int
    ) -> Int? {
        let maxLength = min(left.count, right.count)
        guard maxLength >= minimumLength else { return nil }

        for length in stride(from: maxLength, through: minimumLength, by: -1) {
            if left.suffix(length) == right.prefix(length) {
                return length
            }
        }
        return nil
    }

    private static func rightRemainderAfterNormalizedPrefix(
        _ text: String,
        prefixLength: Int
    ) -> (text: String, continuesToken: Bool) {
        var remaining = prefixLength
        var index = text.startIndex

        while index < text.endIndex, remaining > 0 {
            let character = text[index]
            if !character.isWhitespace && !character.isPunctuation {
                remaining -= 1
            }
            index = text.index(after: index)
        }

        let continuesToken: Bool
        if index > text.startIndex, index < text.endIndex {
            let previous = text[text.index(before: index)]
            let current = text[index]
            continuesToken = !previous.isWhitespace && !previous.isPunctuation && !current.isWhitespace && !current.isPunctuation
        } else {
            continuesToken = false
        }

        return (
            text: text[index...].trimmingCharacters(in: .whitespacesAndNewlines),
            continuesToken: continuesToken
        )
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
