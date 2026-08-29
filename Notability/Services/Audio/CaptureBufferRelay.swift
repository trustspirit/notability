import AVFoundation
import Combine
import os

/// Stamps captured buffers with a start time on a timeline shared by both
/// sources and fans them out to subscribers.
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
///
/// ## The shared origin
///
/// Frame counts alone cannot align the two sources. They start at different
/// moments — the microphone is running long before `SCShareableContent` and
/// `SCStream.startCapture()` have finished, which is hundreds of milliseconds
/// on a good day and seconds the first time permission is granted — so frame
/// *n* of one source is not the same instant as frame *n* of the other.
///
/// So `open()` records a monotonic reading, and a source's first buffer seeds
/// that source's clock with however much of that reading had already elapsed.
/// From then on the clock advances by delivered frames only, which is what
/// keeps spacing immune to a late callback. The result is that both sources'
/// `startTime`s measure from the same instant, which is what lets
/// `SessionRecorder` write index-aligned files and what `AudioMixer` and
/// `SpeakerReferenceExtractor` assume.
///
/// `resynchronize(_:)` re-arms that seeding for one source, for the case where
/// capture was interrupted mid-recording: the frames a restarting engine never
/// delivered are a real hole in the timeline, and counting frames would close
/// the hole up and slide the rest of that track earlier.
final class CaptureBufferRelay: @unchecked Sendable {
    let sampleRate: Double

    /// Reads a monotonic clock, in seconds from an arbitrary fixed point.
    ///
    /// Injectable so the origin can be driven to an exact instant in tests;
    /// nothing about the timeline is observable otherwise, because it depends
    /// on when hardware happens to deliver.
    typealias MonotonicClock = @Sendable () -> TimeInterval

    /// `systemUptime` is `mach_absolute_time` in seconds: monotonic, immune to
    /// the wall clock being set, and paused while the machine is asleep — which
    /// is what we want, because capture is suspended for exactly that interval
    /// and the padding would otherwise cover a sleep the audio never spanned.
    static let systemUptimeClock: MonotonicClock = { ProcessInfo.processInfo.systemUptime }

    private struct SourceState {
        var clock: FrameClock
        /// Set at `open()` and by `resynchronize(_:)`; cleared by the next
        /// buffer, which is the one that establishes where on the shared
        /// timeline this source's audio resumes.
        var needsOrigin = true
        /// RMS of this source's most recent buffer, and when it arrived. Held
        /// per source so the published level can be the meeting's, not
        /// whichever source delivered last; see `combinedLevel`.
        var level: Float = 0
        var levelAt: TimeInterval = -.greatestFiniteMagnitude
    }

    /// How long a source's last level keeps counting toward the published one.
    ///
    /// Both sources deliver every 10–20 ms while they are alive, so this is
    /// never reached in normal capture. It exists for the source that stops
    /// delivering without saying so — a dead stream, a revoked permission —
    /// whose final buffer would otherwise hold the waveform up for the rest of
    /// the meeting.
    private static let levelStaleAfter: TimeInterval = 0.5

    private struct State {
        var isOpen = false
        var openedAt: TimeInterval = 0
        var microphone: SourceState
        var systemAudio: SourceState
    }

    private let clock: MonotonicClock
    private let state: OSAllocatedUnfairLock<State>
    private let buffers = PassthroughSubject<TaggedAudioBuffer, Never>()
    private let levels = PassthroughSubject<Float, Never>()

    init(sampleRate: Double, clock: @escaping MonotonicClock = CaptureBufferRelay.systemUptimeClock) {
        self.sampleRate = sampleRate
        self.clock = clock
        state = OSAllocatedUnfairLock(uncheckedState: State(
            microphone: SourceState(clock: FrameClock(sampleRate: sampleRate)),
            systemAudio: SourceState(clock: FrameClock(sampleRate: sampleRate))
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

    /// Starts accepting buffers, with both clocks back at zero and this instant
    /// as the origin both of them are stamped against.
    func open() {
        let now = clock()
        state.withLockUnchecked { state in
            state.isOpen = true
            state.openedAt = now
            state.microphone = SourceState(clock: FrameClock(sampleRate: sampleRate))
            state.systemAudio = SourceState(clock: FrameClock(sampleRate: sampleRate))
        }
    }

    /// Stops accepting buffers. Once this returns, no buffer reaches a
    /// subscriber, including from a callback that was already under way.
    func close() {
        state.withLockUnchecked { $0.isOpen = false }
    }

    /// Declares that `source` stopped delivering and is about to resume, so its
    /// next buffer should be placed where the shared clock says it is rather
    /// than immediately after the last one.
    ///
    /// Without this, an audio engine restarting for a device change would have
    /// its silent interval erased from the track, sliding everything after it
    /// earlier and out of step with the source that kept running.
    func resynchronize(_ source: AudioSource) {
        state.withLockUnchecked { state in
            switch source {
            case .microphone: state.microphone.needsOrigin = true
            case .systemAudio: state.systemAudio.needsOrigin = true
            }
        }
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
        let now = clock()

        state.withLockUnchecked { state in
            guard state.isOpen else { return }
            let elapsed = now - state.openedAt
            let startTime: TimeInterval
            switch source {
            case .microphone:
                startTime = Self.stamp(&state.microphone, buffer.frameLength, elapsed, sampleRate)
            case .systemAudio:
                startTime = Self.stamp(&state.systemAudio, buffer.frameLength, elapsed, sampleRate)
            }
            switch source {
            case .microphone:
                state.microphone.level = level
                state.microphone.levelAt = elapsed
            case .systemAudio:
                state.systemAudio.level = level
                state.systemAudio.levelAt = elapsed
            }
            buffers.send(TaggedAudioBuffer(source: source, buffer: buffer, startTime: startTime))
            levels.send(Self.combinedLevel(state, at: elapsed))
        }
    }

    /// The loudest source that is still delivering.
    ///
    /// Max rather than a sum: the waveform answers "is anyone talking", and
    /// summing would read two quiet sources as one loud one and clip whenever
    /// both are active.
    private static func combinedLevel(_ state: State, at elapsed: TimeInterval) -> Float {
        var level: Float = 0
        for source in [state.microphone, state.systemAudio] where elapsed - source.levelAt < levelStaleAfter {
            level = max(level, source.level)
        }
        return level
    }

    /// Returns the buffer's start time on the shared timeline, seeding the
    /// source's origin first if this is the buffer that resumes it.
    private static func stamp(
        _ source: inout SourceState,
        _ frameCount: AVAudioFrameCount,
        _ elapsedSinceOpen: TimeInterval,
        _ sampleRate: Double
    ) -> TimeInterval {
        if source.needsOrigin {
            source.needsOrigin = false
            // A capture callback runs once its buffer is full, so the audio in
            // it ends around now and started one buffer's worth earlier.
            // Charging each source only for its own delivery latency is what
            // stops two sources with different buffer sizes from landing a
            // buffer apart.
            let begunAt = elapsedSinceOpen - Double(frameCount) / sampleRate
            source.clock.skip(toFrame: AVAudioFramePosition((begunAt * sampleRate).rounded()))
        }
        return source.clock.advance(by: frameCount)
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
