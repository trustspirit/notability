import Foundation
import Combine

typealias TranscriptionPartialHandler = (String) async -> Void

protocol MeetingStoreProtocol {
    var allMeetings: [Meeting] { get }
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { get }
    func save(_ meeting: Meeting)
    func fetch(id: UUID) -> Meeting?
    func delete(id: UUID)
    // Lightweight update for an in-progress recording's transcript: updates the
    // in-memory snapshot synchronously, but persists to disk on a background
    // queue so the realtime audio path is not blocked by file I/O.
    func persistTranscriptSnapshot(meetingId: UUID, transcript: [TranscriptChunk], durationSeconds: TimeInterval)
}

protocol AudioCaptureServiceProtocol {
    var chunkPublisher: AnyPublisher<(url: URL, timestamp: TimeInterval), Never> { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
    func startCapture() async throws
    func stopCapture() async
}

protocol TranscriptionServiceProtocol {
    func transcribe(
        audioURL: URL,
        timestamp: TimeInterval,
        prompt: String?,
        onPartialTranscript: TranscriptionPartialHandler?
    ) async throws -> TranscriptChunk
}

extension TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, timestamp: TimeInterval, prompt: String? = nil) async throws -> TranscriptChunk {
        try await transcribe(
            audioURL: audioURL,
            timestamp: timestamp,
            prompt: prompt,
            onPartialTranscript: nil
        )
    }
}

protocol NoteGenerationServiceProtocol {
    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes
}

protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
