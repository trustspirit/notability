import AVFoundation
import os

/// Resamples capture buffers into one target format, reusing a single
/// `AVAudioConverter` across the whole stream.
///
/// The lock guards the converter and nothing else: it carries resampling state
/// across calls and two threads entering it at once would corrupt it. It
/// deliberately does not order anything — it is released before the caller
/// touches the result, so callers that need ordered output must keep one thread
/// per stream.
final class ResamplingConverter: @unchecked Sendable {
    let targetFormat: AVAudioFormat

    private let converter = OSAllocatedUnfairLock<AVAudioConverter?>(uncheckedState: nil)

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// Returns `buffer` itself when it already matches `targetFormat`, so the
    /// result is not always storage this converter owns. Callers that publish
    /// the result past the lifetime of the input must copy in that case.
    ///
    /// Returns nil while the resampler is still priming, which is normal for the
    /// first buffer: those frames are held internally and come out with the next
    /// one.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !buffer.format.isEqual(targetFormat) else { return buffer }

        return converter.withLockUnchecked { converter in
            // Rebuilt on demand rather than once up front, because the capture
            // format changes when the user switches input device.
            if converter?.inputFormat.isEqual(buffer.format) != true {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter else { return nil }
            return render(buffer, through: converter)
        }
    }

    /// Drops the cached converter so the next buffer builds a fresh one. Used
    /// when the input device changes and the resampler state no longer belongs
    /// to the incoming audio.
    func reset() {
        converter.withLockUnchecked { $0 = nil }
    }

    private func render(_ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !consumed else {
                // .noDataNow leaves the converter resumable. Reporting
                // .endOfStream here would retire it after the first buffer and
                // silently drop every buffer for the rest of the recording.
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
