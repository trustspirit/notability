import AVFoundation
import Combine
import os

/// Stamps captured buffers with a frame-derived start time and fans them out to
/// subscribers.
///
/// Two realtime callers share this: the audio engine's microphone tap thread and
/// ScreenCaptureKit's sample queue. One lock covers everything they share — the
/// gate, both frame clocks, and the Combine subjects, whose `send` is not safe
/// to call from two threads at once.
///
/// Publishing happens inside that lock, which buys two properties:
///
/// - The gate closes completely. It is read in the same critical section that
///   publishes, so a callback already under way when `close()` runs finds the
///   gate shut and drops its buffer; nothing reaches a subscriber after
///   `close()` returns.
/// - Subscribers see one delivery at a time, so downstream code that is safe on
///   one thread stays safe here.
///
/// The cost is that one source's callback can wait for the other source's
/// subscribers to finish. `OSAllocatedUnfairLock` donates priority to whichever
/// thread holds it, so the realtime microphone thread is not left waiting behind
/// a preempted ScreenCaptureKit queue. Subscribers must therefore not block, and
/// must not call back into this relay synchronously — that deadlocks rather than
/// corrupting anything, which is the failure mode worth having.
///
/// Order within a source needs no help from the lock: each source has exactly
/// one sending thread, and stamping and publishing happen in the same call.
/// Order between sources is not preserved and does not need to be — the two
/// tracks are aligned downstream by their timestamps.
final class CaptureBufferRelay: @unchecked Sendable {
    let sampleRate: Double

    private struct State {
        var isOpen = false
        var microphoneClock: FrameClock
        var systemAudioClock: FrameClock
    }

    private let state: OSAllocatedUnfairLock<State>
    private let buffers = PassthroughSubject<TaggedAudioBuffer, Never>()
    private let levels = PassthroughSubject<Float, Never>()

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        state = OSAllocatedUnfairLock(uncheckedState: State(
            microphoneClock: FrameClock(sampleRate: sampleRate),
            systemAudioClock: FrameClock(sampleRate: sampleRate)
        ))
    }

    /// Never completes and is never replaced, so a subscription taken at any
    /// point spans any number of recordings.
    var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> {
        buffers.eraseToAnyPublisher()
    }

    /// RMS of each published buffer, delivered on the capture thread.
    var levelPublisher: AnyPublisher<Float, Never> {
        levels.eraseToAnyPublisher()
    }

    var isOpen: Bool {
        state.withLockUnchecked { $0.isOpen }
    }

    /// Starts accepting buffers, with both clocks back at zero so timestamps are
    /// relative to this recording.
    func open() {
        state.withLockUnchecked { state in
            state.isOpen = true
            state.microphoneClock = FrameClock(sampleRate: sampleRate)
            state.systemAudioClock = FrameClock(sampleRate: sampleRate)
        }
    }

    /// Stops accepting buffers. Once this returns, no buffer reaches a
    /// subscriber, including from a callback that was already under way.
    func close() {
        state.withLockUnchecked { $0.isOpen = false }
    }

    /// Publishes `buffer` as coming from `source`.
    ///
    /// Call synchronously from the capture callback that produced the buffer,
    /// one thread per source. `buffer` must be storage the caller owns and does
    /// not reuse: subscribers hold on to it after this returns.
    func send(_ buffer: AVAudioPCMBuffer, from source: AudioSource) {
        // Zero frames would repeat the previous timestamp, and SpeechAnalyzer
        // rejects timecodes that do not strictly increase.
        guard buffer.frameLength > 0 else { return }

        // Computed before the lock to keep the critical section to a clock
        // update and two sends.
        let level = Self.rms(of: buffer)

        state.withLockUnchecked { state in
            guard state.isOpen else { return }
            let startTime: TimeInterval
            switch source {
            case .microphone:
                startTime = state.microphoneClock.advance(by: buffer.frameLength)
            case .systemAudio:
                startTime = state.systemAudioClock.advance(by: buffer.frameLength)
            }
            buffers.send(TaggedAudioBuffer(source: source, buffer: buffer, startTime: startTime))
            levels.send(level)
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = Float(samples[index]) / 32_768
            sum += sample * sample
        }
        return sqrt(sum / Float(buffer.frameLength))
    }
}
