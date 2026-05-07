import Foundation
import Combine
import UserNotifications

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var liveTranscript: [TranscriptChunk] = []

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcription: TranscriptionServiceProtocol
    private let noteGeneration: NoteGenerationServiceProtocol
    private let store: MeetingStoreProtocol
    private var cancellables = Set<AnyCancellable>()
    private var currentMeetingId: UUID?
    private var elapsedTimer: Timer?
    private var recordingStart: Date?

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

    func startRecording() async throws {
        let id = UUID()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "Meeting - \(formatter.string(from: Date()))"
        let meeting = Meeting(id: id, title: title, date: Date(), durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
        store.save(meeting)
        currentMeetingId = id
        liveTranscript = []

        audioCapture.chunkPublisher
            .sink { [weak self] chunk in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleChunk(chunk, meetingId: id)
                }
            }
            .store(in: &cancellables)

        try await audioCapture.startCapture()
        recordingStart = Date()
        state = .recording(elapsed: 0)

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.state = .recording(elapsed: Date().timeIntervalSince(start))
            }
        }
    }

    func stopRecording() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioCapture.stopCapture()

        guard let id = currentMeetingId else { return }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0

        var meeting = store.fetch(id: id) ?? Meeting(id: id, title: "Meeting", date: Date(), durationSeconds: duration, transcript: liveTranscript, notes: nil, notesGenerationError: nil)
        meeting.durationSeconds = duration
        meeting.transcript = liveTranscript
        store.save(meeting)

        state = .processing
        cancellables.removeAll()

        do {
            let notes = try await noteGeneration.generateNotes(transcript: liveTranscript)
            meeting.notes = notes
            store.save(meeting)
            state = .done(meetingId: id)
            sendCompletionNotification()
        } catch {
            meeting.notesGenerationError = error.localizedDescription
            store.save(meeting)
            state = .failed(error.localizedDescription)
        }
    }

    private func handleChunk(_ chunk: (url: URL, timestamp: TimeInterval), meetingId: UUID) async {
        do {
            let transcriptChunk = try await transcription.transcribe(audioURL: chunk.url, timestamp: chunk.timestamp)
            liveTranscript.append(transcriptChunk)
            if var meeting = store.fetch(id: meetingId) {
                meeting.transcript = liveTranscript
                store.save(meeting)
            }
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
