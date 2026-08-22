import Foundation
import Combine
import AVFoundation

typealias TranscriptionPartialHandler = (String) async -> Void

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
    /// Tagged PCM buffers, published as they arrive. No disk round-trip.
    ///
    /// Neither replaced nor completed for the lifetime of the service, so one
    /// subscription spans any number of recordings and it does not matter
    /// whether it is taken before or after `startCapture()`. `stopCapture()`
    /// only stops the flow of values; subscribers end their own subscription.
    ///
    /// Values arrive synchronously on the thread that captured them — the audio
    /// engine's tap thread for `.microphone`, ScreenCaptureKit's sample queue
    /// for `.systemAudio` — which is exactly one thread per source, so a
    /// subscriber may hand a buffer straight to
    /// `LiveTranscriptionServiceProtocol.append` without wrapping it in a task.
    /// Deliveries are serialized across the two sources, so a subscriber that
    /// blocks delays the other source's capture callback, and a subscriber that
    /// reenters the capture service synchronously deadlocks.
    ///
    /// Buffers are always in `captureFormat`, and each one's `startTime` is
    /// derived from its own source's accumulated frame count. The two sources'
    /// timelines are independent: they both start at zero and advance only with
    /// the frames that source delivered.
    var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> { get }

    /// RMS amplitude, 0...1, of every published buffer, for the level meter.
    /// Delivered on the capture threads described above, so hop to the main
    /// queue before touching UI.
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }

    /// Replays the current value on subscription and emits on every change,
    /// delivered on the main queue, so a view built after capture started still
    /// sees the truth.
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> { get }

    /// True while system audio is attached. False when only the microphone is
    /// being captured (e.g. the user denied Screen Recording permission), which
    /// `startCapture()` treats as success.
    var isCapturingSystemAudio: Bool { get }

    /// True while microphone input is attached. Recording requires this so the
    /// local user's voice is included.
    var isCapturingMicrophone: Bool { get }

    /// Whether the system echo canceller is running on the microphone input.
    ///
    /// `startCapture()` succeeds either way, because a recording without echo
    /// cancellation is still worth having. False means meeting audio coming back
    /// through the speakers is also in the microphone track, so the far end gets
    /// transcribed and billed twice — worth telling the user about. Reflects the
    /// attempt made when capture started.
    var isEchoCancellationEnabled: Bool { get }

    /// 16 kHz mono Int16. Recording, live captions and mixing all assume it.
    var captureFormat: AVAudioFormat { get }

    /// Starts from a clean slate: any previous capture is stopped and both
    /// timelines restart at zero.
    ///
    /// Succeeds with the microphone alone. It throws only when the microphone is
    /// unavailable, because a recording without the local user's voice is not
    /// worth keeping.
    ///
    /// Must not overlap with another `startCapture()` or `stopCapture()` — one
    /// recording at a time.
    func startCapture() async throws

    /// Stops every source. Once it returns, no further buffer is published.
    /// Safe to call when nothing is running, and safe to call twice.
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
/// `prepare` and `finish` need one serialized context, because they hand state
/// to each other across suspension points; the main actor is that context, and
/// the isolation here is what enforces it rather than a convention callers have
/// to remember.
///
/// `append` opts back out: it is driven from realtime audio callbacks, so it
/// stays synchronous and free-threaded. That freedom carries two ordering
/// obligations, because a source whose buffers reach the analyzer out of order
/// is rejected as disordered audio and loses captions for the rest of the
/// recording:
///
/// - Never wrap `append` in a task. Call it synchronously from the callback.
/// - At most one thread may append for a given source at a time. Different
///   sources are independent and may append concurrently. An implementation can
///   lock its own internals, but no lock can recover an order the caller has
///   already lost, so this obligation cannot be delegated to one.
@MainActor
protocol LiveTranscriptionServiceProtocol: AnyObject {
    nonisolated var events: AsyncStream<LiveTranscriptionEvent> { get }
    func prepare(sources: [AudioSource], locale: Locale) async
    nonisolated func append(_ buffer: TaggedAudioBuffer)
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
