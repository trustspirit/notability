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

enum LiveTranscriptionEvent: Equatable {
    /// Speech model asset download in progress, 0...1. Roughly 300 MB on first
    /// run for Korean, so this needs to be visible rather than a silent stall.
    case downloading(progress: Double)
    /// Analyzers are running; any download notice can be cleared.
    case ready
    /// Provisional text that replaces the previous volatile text for this source.
    case volatile(source: AudioSource, text: String, startTime: TimeInterval)
    /// Confirmed text. Clears any volatile text for this source.
    case finalized(source: AudioSource, text: String, startTime: TimeInterval)
    /// Live captions cannot run. Recording continues; the final pass is unaffected.
    case unavailable(String)
}

/// Display-only captions produced while recording. Implementations are single
/// use: `events` terminates on `finish()` and `prepare` must not be called
/// again afterwards, so a new recording needs a new instance.
///
/// `prepare` and `finish` must be called from one serialized context. `append`
/// is free-threaded by design — it is driven from realtime audio callbacks and
/// must never be wrapped in a task, because that would reorder buffers.
protocol LiveTranscriptionServiceProtocol: AnyObject {
    var events: AsyncStream<LiveTranscriptionEvent> { get }
    func prepare(sources: [AudioSource], locale: Locale) async
    func append(_ buffer: TaggedAudioBuffer)
    func finish() async
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
