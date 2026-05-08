import Foundation
import Combine
import UserNotifications

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published var liveTranscript: [TranscriptChunk] = []

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcription: TranscriptionServiceProtocol
    private let noteGeneration: NoteGenerationServiceProtocol
    private let store: MeetingStoreProtocol
    private var chunkHandlingTask: Task<Void, Never>?
    private var currentMeetingId: UUID?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

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
        liveTranscript = []
        chunkHandlingTask?.cancel()

        // Start capture first — only save meeting if it actually succeeds.
        try await audioCapture.startCapture()

        let title = "Meeting - \(Self.titleFormatter.string(from: Date()))"
        let meeting = Meeting(id: id, title: title, date: Date(), durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
        store.save(meeting)
        currentMeetingId = id
        recordingStart = Date()
        state = .recording(elapsed: 0)

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
                    let meetingId = id
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.handleChunk(chunk, meetingId: meetingId)
                    }
                }
            }
        }
    }

    func stopRecording() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        // stopCapture() flushes the final partial chunk (synchronously) then
        // sends .finished on the publisher, causing the for-await loop in
        // chunkHandlingTask to exit after all in-flight Tasks complete.
        await audioCapture.stopCapture()
        await chunkHandlingTask?.value
        chunkHandlingTask = nil

        guard let id = currentMeetingId else { return }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0

        var meeting = store.fetch(id: id) ?? Meeting(id: id, title: "Meeting", date: Date(), durationSeconds: duration, transcript: liveTranscript, notes: nil, notesGenerationError: nil)
        meeting.durationSeconds = duration
        meeting.transcript = liveTranscript
        store.save(meeting)

        state = .processing

        do {
            let validTranscript = liveTranscript.filter { $0.text != "[transcription failed]" }
            let notes = try await noteGeneration.generateNotes(transcript: validTranscript)
            meeting.notes = notes
            store.save(meeting)
            state = .done(meetingId: id)
            sendCompletionNotification()
        } catch {
            meeting.notesGenerationError = error.localizedDescription
            store.save(meeting)
            state = .failed(error.localizedDescription)
        }
        currentMeetingId = nil
        recordingStart = nil
    }

    private func handleChunk(_ chunk: (url: URL, timestamp: TimeInterval), meetingId: UUID) async {
        do {
            let transcriptChunk = try await transcription.transcribe(audioURL: chunk.url, timestamp: chunk.timestamp)
            liveTranscript.append(transcriptChunk)
        } catch {
            let errorChunk = TranscriptChunk(timestamp: chunk.timestamp, text: "[transcription failed]")
            liveTranscript.append(errorChunk)
        }
    }

    private func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting notes ready"
        content.body = "Your meeting notes have been generated."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
