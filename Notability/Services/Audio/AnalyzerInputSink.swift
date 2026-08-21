import AVFoundation
import Speech
import os

/// One capture source's path from the audio thread into its `SpeechAnalyzer`.
///
/// Built while `prepare` runs and then only read, so an audio callback can use
/// it without going back through the registry that owns it.
///
/// The lock guards the `AVAudioConverter` and nothing else: it carries
/// resampling state across calls and two threads entering it at once would
/// corrupt it. It deliberately does not order delivery — it is released before
/// the yield, so two threads sending for this source could convert in lock
/// order and still reach the analyzer reversed. Keeping one appender per source
/// is the caller's contract; see `LiveTranscriptionServiceProtocol`.
final class AnalyzerInputSink: @unchecked Sendable {
    /// Format the analyzer advertised, or nil to feed buffers through unchanged.
    let targetFormat: AVAudioFormat?

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter = OSAllocatedUnfairLock<AVAudioConverter?>(uncheckedState: nil)

    /// Nanoseconds resolve every 16 kHz frame boundary exactly, so timestamps
    /// stay strictly increasing after the round trip through `CMTime`.
    private static let timescale: CMTimeScale = 1_000_000_000

    init(targetFormat: AVAudioFormat?, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    /// Hands a captured buffer to the analyzer, resampling first if needed.
    ///
    /// Called synchronously from a realtime audio thread, one thread at a time
    /// for this sink. Yielding into an unbounded `AsyncStream` never suspends
    /// and never drops, which matters because a missing buffer leaves a hole
    /// the analyzer reads as disordered audio and then rejects everything
    /// after it.
    func send(_ tagged: TaggedAudioBuffer) {
        // A zero-frame buffer repeats the previous timestamp, and SpeechAnalyzer
        // requires strictly increasing ones.
        guard tagged.buffer.frameLength > 0 else { return }
        guard let buffer = convert(tagged.buffer) else { return }

        continuation.yield(AnalyzerInput(
            buffer: buffer,
            bufferStartTime: CMTime(seconds: tagged.startTime, preferredTimescale: Self.timescale)
        ))
    }

    func finish() {
        continuation.finish()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = targetFormat, !buffer.format.isEqual(target) else { return buffer }

        return converter.withLockUnchecked { converter in
            // Rebuilt on demand rather than once in `prepare`, because the
            // capture format changes when the user switches input device.
            if converter?.inputFormat.isEqual(buffer.format) != true {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return nil }
            return Self.render(buffer, through: converter, to: target)
        }
    }

    private static func render(
        _ buffer: AVAudioPCMBuffer,
        through converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !consumed else {
                // .noDataNow leaves the converter resumable. Reporting
                // .endOfStream here would retire it after the first buffer and
                // silently kill captions for the rest of the recording.
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        // A dry first call is normal while the resampler primes; the frames are
        // held internally and come out with the next buffer.
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Maps capture sources to their analyzer input sinks.
///
/// `prepare` and `finish` mutate this from the main actor while capture
/// callbacks read it from realtime audio threads. Every access takes an unfair
/// lock. The read path an audio thread takes is one dictionary lookup: no
/// allocation, no framework calls, no I/O. The write paths can allocate —
/// `register` on dictionary growth, `removeAll` for the array it hands back —
/// but they run at most once per source per recording, and priority inheritance
/// keeps a preempted writer from stalling the audio thread behind them.
final class AnalyzerInputRegistry: @unchecked Sendable {
    private let sinks = OSAllocatedUnfairLock<[AudioSource: AnalyzerInputSink]>(uncheckedState: [:])

    var isEmpty: Bool {
        sinks.withLockUnchecked { $0.isEmpty }
    }

    func register(_ sink: AnalyzerInputSink, for source: AudioSource) {
        sinks.withLockUnchecked { $0[source] = sink }
    }

    func sink(for source: AudioSource) -> AnalyzerInputSink? {
        sinks.withLockUnchecked { $0[source] }
    }

    /// Empties the registry and returns what it held, so a concurrent `append`
    /// stops finding sinks before any of them is finished.
    func removeAll() -> [AnalyzerInputSink] {
        sinks.withLockUnchecked { registered in
            defer { registered.removeAll() }
            return Array(registered.values)
        }
    }
}
