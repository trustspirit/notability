import Foundation
import Combine

protocol MeetingStoreProtocol {
    var allMeetings: [Meeting] { get }
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { get }
    func save(_ meeting: Meeting)
    func fetch(id: UUID) -> Meeting?
    func delete(id: UUID)
}

protocol AudioCaptureServiceProtocol {
    var chunkPublisher: AnyPublisher<(url: URL, timestamp: TimeInterval), Never> { get }
    func startCapture() async throws
    func stopCapture()
}

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, timestamp: TimeInterval) async throws -> TranscriptChunk
}

protocol NoteGenerationServiceProtocol {
    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes
}

protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
