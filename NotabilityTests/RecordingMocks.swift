import AVFoundation
import Combine
import Foundation
import os
@testable import Notability

/// Stands in for `AudioCaptureService`, reproducing the delivery semantics the
/// coordinator has to cope with rather than the ones that are convenient to
/// assert on.
///
/// Two of those semantics are load-bearing and a main-queue-only mock cannot
/// express either. Buffers reach subscribers synchronously on the thread that
/// called `emit`, serialized across sources by one lock, exactly as
/// `CaptureBufferRelay` does. And the availability subjects publish their
/// changes through a main-queue hop while the matching `isCapturing…` getter
/// updates immediately, which is what opens the window where a subscriber's
/// replayed value is still the pre-start `false`.
final class MockAudioCaptureService: AudioCaptureServiceProtocol, @unchecked Sendable {
    private let buffers = PassthroughSubject<TaggedAudioBuffer, Never>()
    private let levels = PassthroughSubject<Float, Never>()
    private let systemAudioAvailability = CurrentValueSubject<Bool, Never>(true)
    private let microphoneAvailability = CurrentValueSubject<Bool, Never>(true)
    /// `PassthroughSubject.send` is not safe from two threads at once, and the
    /// real relay holds a lock across the whole fan-out.
    private let deliveryLock = OSAllocatedUnfairLock()

    var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> { buffers.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { levels.eraseToAnyPublisher() }
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> {
        systemAudioAvailability.eraseToAnyPublisher()
    }
    var microphoneAvailabilityPublisher: AnyPublisher<Bool, Never> {
        microphoneAvailability.eraseToAnyPublisher()
    }

    var isCapturingSystemAudio = true {
        didSet { publishAvailability(isCapturingSystemAudio, on: systemAudioAvailability) }
    }
    var isCapturingMicrophone = true {
        didSet { publishAvailability(isCapturingMicrophone, on: microphoneAvailability) }
    }
    var isEchoCancellationEnabled = true
    let captureFormat = AudioFixtures.format

    private let calls = OSAllocatedUnfairLock(initialState: Calls())
    private struct Calls {
        var start = 0
        var stop = 0
    }

    var startCallCount: Int { calls.withLock { $0.start } }
    var stopCallCount: Int { calls.withLock { $0.stop } }
    var startError: Error?

    /// Holds `startCapture` open, the way waiting on a permission prompt does, so
    /// a test can act on the coordinator while the first start is still
    /// suspended. Armed before the call; released by the test.
    private var startGate: AsyncStream<Void>?
    private var startGateContinuation: AsyncStream<Void>.Continuation?

    /// Called once `startCapture` has reached the gate, so a test can wait for
    /// the suspension rather than guess when it happens.
    var onStartSuspended: (() -> Void)?

    func blockStart() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        startGate = stream
        startGateContinuation = continuation
    }

    func releaseStart() {
        startGateContinuation?.finish()
    }

    /// The mode of the most recent `startCapture`, so a test can assert what
    /// the coordinator asked for rather than what it happened to record.
    private(set) var lastStartMode: RecordingMode?

    func startCapture(mode: RecordingMode) async throws {
        calls.withLock { $0.start += 1 }
        lastStartMode = mode
        if let startGate {
            onStartSuspended?()
            for await _ in startGate {}
        }
        if let startError { throw startError }
    }

    func stopCapture() async {
        calls.withLock { $0.stop += 1 }
    }

    /// Publishes on the calling thread, like the real capture callbacks.
    func emit(source: AudioSource, buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        buffers.send(TaggedAudioBuffer(source: source, buffer: buffer, startTime: startTime))
        levels.send(AudioFixtures.rms(of: buffer))
    }

    /// Emits from a thread that is neither the main queue nor a cooperative-pool
    /// worker, and returns that thread's id so a test can assert where the
    /// buffer ended up.
    @discardableResult
    func emitFromCaptureThread(
        source: AudioSource,
        buffer: AVAudioPCMBuffer,
        startTime: TimeInterval
    ) -> UInt64 {
        onDedicatedThread { [self] in
            emit(source: source, buffer: buffer, startTime: startTime)
        }
    }

    /// Sets the replayed availability value without touching the getter, which
    /// is how the real service looks between `startCapture()` returning and its
    /// main-queue availability send landing.
    func seedMicrophoneAvailability(_ value: Bool) {
        microphoneAvailability.send(value)
    }

    private func publishAvailability(_ value: Bool, on subject: CurrentValueSubject<Bool, Never>) {
        DispatchQueue.main.async { subject.send(value) }
    }
}

/// Records what it was asked to write and from where, so the recorder half of
/// the buffer fan-out can be asserted on without going through AAC encoding.
final class FakeSessionAudioWriter: SessionAudioWriting, @unchecked Sendable {
    let url: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var appendedFrameCounts: [AVAudioFrameCount] = []
        var appendedStartTimes: [TimeInterval] = []
        var appendThreadIDs: [UInt64] = []
        var didFinish = false
        var writeError: Error?
    }

    init(url: URL) {
        self.url = url
    }

    var appendedFrameCounts: [AVAudioFrameCount] { state.withLock { $0.appendedFrameCounts } }
    var appendedStartTimes: [TimeInterval] { state.withLock { $0.appendedStartTimes } }
    var appendThreadIDs: [UInt64] { state.withLock { $0.appendThreadIDs } }
    var didFinish: Bool { state.withLock { $0.didFinish } }

    var writeError: Error? {
        get { state.withLock { $0.writeError } }
        set { state.withLock { $0.writeError = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        let id = currentThreadID()
        state.withLock {
            $0.appendedFrameCounts.append(buffer.frameLength)
            $0.appendedStartTimes.append(startTime)
            $0.appendThreadIDs.append(id)
        }
    }

    func finish() {
        state.withLock { $0.didFinish = true }
    }
}

/// Holds a mock service inside its call until a test lets it go.
///
/// The only way to observe what the pipeline does with a meeting it snapshotted
/// is to act on the store while the pipeline is suspended in one of its awaits,
/// which means suspending it somewhere a test controls.
final class CallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: AsyncStream<Void>?
    private var continuation: AsyncStream<Void>.Continuation?

    /// Called on the suspending thread once the gate has been reached, so a test
    /// can wait for the suspension instead of guessing when it happens.
    var onEntered: (() -> Void)?

    func arm() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            self.stream = stream
            self.continuation = continuation
        }
    }

    func release() {
        lock.withLock { continuation }?.finish()
    }

    /// Suspends until `release()`, or returns immediately if never armed.
    func wait() async {
        guard let stream = lock.withLock({ stream }) else { return }
        onEntered?()
        for await _ in stream {}
    }
}

final class MockFinalTranscriptionService: FinalTranscriptionServiceProtocol, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())
    let gate = CallGate()

    private struct State {
        var result = DiarizedTranscription(chunks: [], billedSeconds: nil)
        var error: Error?
        var callCount = 0
        var receivedSpeakerReferences: [Data?] = []
    }

    var result: DiarizedTranscription {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    var error: Error? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }

    var callCount: Int { state.withLock { $0.callCount } }
    var receivedSpeakerReferences: [Data?] { state.withLock { $0.receivedSpeakerReferences } }

    func transcribe(
        audioURL: URL,
        speakerReference: Data?,
        language: String?
    ) async throws -> DiarizedTranscription {
        let outcome: (result: DiarizedTranscription, error: Error?) = state.withLock {
            $0.callCount += 1
            $0.receivedSpeakerReferences.append(speakerReference)
            return ($0.result, $0.error)
        }
        await gate.wait()
        if let error = outcome.error { throw error }
        return outcome.result
    }
}

final class MockNoteGenerationService: NoteGenerationServiceProtocol, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())
    let gate = CallGate()

    private struct State {
        var error: Error?
        var callCount = 0
        var receivedTranscripts: [[TranscriptChunk]] = []
    }

    var error: Error? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }

    var callCount: Int { state.withLock { $0.callCount } }
    var receivedTranscripts: [[TranscriptChunk]] { state.withLock { $0.receivedTranscripts } }

    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes {
        let error: Error? = state.withLock {
            $0.callCount += 1
            $0.receivedTranscripts.append(transcript)
            return $0.error
        }
        await gate.wait()
        if let error { throw error }
        return MeetingNotes(summary: "Mock summary", actionItems: [], keyDecisions: [])
    }
}

struct StubProcessingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AudioFixtures {
    /// Root-mean-square amplitude of an in-memory buffer, 0...1.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = Float(samples[index]) / 32_768
            sum += sample * sample
        }
        return sqrt(sum / Float(buffer.frameLength))
    }
}
