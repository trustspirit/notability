import Foundation
import Combine
import AVFoundation

protocol MeetingStoreProtocol {
    var allMeetings: [Meeting] { get }
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { get }
    func save(_ meeting: Meeting)
    func fetch(id: UUID) -> Meeting?
    /// Read-modify-write against the stored copy. Anything that mutates a
    /// meeting across a suspension point has to go through this rather than
    /// saving what it read; see the implementation for what that costs when it
    /// does not.
    func update(id: UUID, _ transform: (inout Meeting) -> Void)
    func delete(id: UUID)
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
    /// Buffers are always in `captureFormat`, and every one's `startTime` is
    /// measured from a single origin shared by both sources: the instant
    /// `startCapture()` began attaching them. So equal `startTime`s mean the
    /// same moment of the meeting whichever source they came from, which is
    /// what makes the two recorded tracks alignable by sample index.
    ///
    /// Within a source, spacing comes from delivered frames rather than from
    /// the clock, so a late callback does not shift the audio it carries. The
    /// clock is consulted only where frames cannot answer: the first buffer of
    /// each source, since the two sources start seconds apart, and the first
    /// buffer after an interruption, since the frames that were never delivered
    /// are a real gap. A `startTime` therefore need not equal the total frames
    /// that source has delivered, and consumers that write these buffers to
    /// disk must fill the difference rather than concatenate.
    var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> { get }

    /// RMS amplitude, 0...1, of every published buffer, for the level meter.
    /// Delivered on the capture threads described above, so hop to the main
    /// queue before touching UI.
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }

    /// Replays the current value on subscription and emits on every change, so a
    /// view built after capture started still sees the truth.
    ///
    /// Changes arrive on the main queue. The replayed value does not: it is
    /// delivered synchronously on whichever thread subscribed. Subscribe from the
    /// main queue, or add `.receive(on:)`, rather than assuming both are hopped.
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> { get }

    /// True while system audio is attached. False when only the microphone is
    /// being captured (e.g. the user denied Screen Recording permission), which
    /// `startCapture()` treats as success.
    var isCapturingSystemAudio: Bool { get }

    /// True while microphone input is attached. Recording requires this so the
    /// local user's voice is included.
    var isCapturingMicrophone: Bool { get }

    /// Tracks `isCapturingMicrophone`, with the same delivery caveat as
    /// `systemAudioAvailabilityPublisher`.
    ///
    /// This can go false mid-recording: switching input device restarts the audio
    /// engine, and a restart that fails costs the local user's voice from that
    /// point on while system audio keeps recording. `startCapture()` throwing on
    /// microphone failure exists because a recording without the local voice is
    /// not worth keeping, so the same failure arriving later deserves the same
    /// treatment — which is only possible if someone is watching this.
    var microphoneAvailabilityPublisher: AnyPublisher<Bool, Never> { get }

    /// Whether the system echo canceller is running on the microphone input.
    ///
    /// `startCapture()` succeeds either way, because a recording without echo
    /// cancellation is still worth having. False means meeting audio coming back
    /// through the speakers is also in the microphone track, so the mix carries
    /// the far end twice. Cost is unaffected — the mix is one upload whose length
    /// is the wall clock — but the duplicate can be transcribed twice and
    /// attributed to the local speaker, whose voice the speaker reference has
    /// already named. Reflects the attempt made when capture started.
    var isEchoCancellationEnabled: Bool { get }

    /// 16 kHz mono Int16. Recording is written at this rate; live captions and
    /// mixing resample away from it, so they depend on it being reported
    /// accurately rather than on the value itself.
    var captureFormat: AVAudioFormat { get }

    /// Starts from a clean slate: any previous capture is stopped and the
    /// shared timeline restarts at zero.
    ///
    /// Succeeds with the microphone alone. It throws only when the microphone is
    /// unavailable, because a recording without the local user's voice is not
    /// worth keeping.
    ///
    /// Must not overlap with another `startCapture()` or `stopCapture()` — one
    /// recording at a time.
    func startCapture(mode: RecordingMode) async throws

    /// Stops every source. Once it returns, no further buffer is published.
    /// Safe to call when nothing is running, and safe to call twice.
    ///
    /// `stopDelivery()` followed by `finishTeardown()`. Callers that have
    /// something to close of their own want those halves apart; callers that
    /// only want the capture path gone want this.
    func stopCapture() async

    /// Stops the flow of buffers and releases the microphone, synchronously.
    ///
    /// Everything it touches is the app's own, so it returns promptly and cannot
    /// suspend. Once it returns no buffer is published and none can start being
    /// published, which is what makes it safe to finish the consumers those
    /// buffers were feeding — without first waiting on `finishTeardown()`, which
    /// may never come back.
    ///
    /// On the main actor because it is the synchronous half: it mutates the
    /// engine the capture path is built on, which is what the implementation is
    /// isolated to in the first place. `async` requirements can hop there on
    /// their own; this one has to be declared there.
    @MainActor func stopDelivery()

    /// Releases the operating system's capture sessions.
    ///
    /// Split from `stopDelivery()` because this half asks frameworks to let go
    /// and they do not promise to answer: a ScreenCaptureKit stream that has
    /// already died can leave its `stopCapture()` suspended for the life of the
    /// process. Nothing the app promised the user depends on this returning, so
    /// callers on the way out should bound how long they wait for it.
    func finishTeardown() async
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

protocol NoteGenerationServiceProtocol {
    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes
}

protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
