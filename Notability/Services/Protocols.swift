import Foundation
import Combine

typealias TranscriptionPartialHandler = (String) async -> Void
typealias AudioChunk = (url: URL, timestamp: TimeInterval)

protocol MeetingStoreProtocol {
    var allMeetings: [Meeting] { get }
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { get }
    func save(_ meeting: Meeting)
    func fetch(id: UUID) -> Meeting?
    func delete(id: UUID)
    // Streaming transcript updates during recording — skips the full-save cost.
    // Use save() instead when fields beyond transcript/duration may change.
    func persistTranscriptSnapshot(id: UUID, transcript: [TranscriptChunk], durationSeconds: TimeInterval)
}

protocol AudioCaptureServiceProtocol {
    var chunkPublisher: AnyPublisher<AudioChunk, Never> { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> { get }
    // True after startCapture() succeeds with system audio attached. False
    // when only the microphone is being captured (e.g. user denied screen
    // recording permission). Read after startCapture() returns.
    var isCapturingSystemAudio: Bool { get }
    // True after startCapture() succeeds with microphone input attached.
    // Recording requires this so the local user's voice is included.
    var isCapturingMicrophone: Bool { get }
    func startCapture() async throws
    func stopCapture() async
}

struct DiarizedTranscription: Equatable {
    let chunks: [TranscriptChunk]
    /// usage.seconds reported by the API, for cost display. nil when absent.
    let billedSeconds: Int?
}

protocol FinalTranscriptionServiceProtocol {
    func transcribe(
        audioURL: URL,
        speakerReference: Data?,
        language: String?
    ) async throws -> DiarizedTranscription
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
