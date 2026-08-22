import XCTest
import AVFoundation
@testable import Notability

/// `AVAudioConverter`'s input block is easy to get wrong in a way that only
/// shows from the second buffer onwards, so every assertion here is on the
/// frame total across a stream. A single converted buffer always looks
/// plausible, which is exactly why one-buffer tests missed the bug twice.
final class ResamplingConverterTests: XCTestCase {
    private let target = AudioFixtures.format

    /// `AVAudioConverter`'s sample-rate converter keeps a fixed amount of
    /// latency inside itself that is never flushed, measured at a little over a
    /// thousand frames however long the stream is. The failure this file exists
    /// to catch loses around nine tenths of the stream, so a constant of this
    /// size still separates the two cleanly.
    private static let resamplerLatency: Double = 2_048

    private static func float32(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    private static func tone(seconds: Double, in format: AVAudioFormat, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let value = amplitude * sinf(2 * .pi * 440 * Float(index) / Float(format.sampleRate))
            if let floats = buffer.floatChannelData {
                floats[0][index] = value
            } else if let ints = buffer.int16ChannelData {
                ints[0][index] = Int16(value * 32_767)
            }
        }
        return buffer
    }

    private func totalFrames(of buffers: [AVAudioPCMBuffer], through sut: ResamplingConverter) -> Int {
        buffers.compactMap { sut.convert($0) }.reduce(0) { $0 + Int($1.frameLength) }
    }

    func test_hands_the_buffer_back_untouched_when_it_already_matches_the_target() {
        let sut = ResamplingConverter(targetFormat: target)
        let buffer = AudioFixtures.tone(seconds: 0.1)

        XCTAssertTrue(sut.convert(buffer) === buffer)
    }

    func test_keeps_converting_after_the_first_buffer() {
        let sut = ResamplingConverter(targetFormat: target)
        let buffers = (0..<10).map { _ in Self.tone(seconds: 0.1, in: Self.float32(sampleRate: 48_000)) }

        let produced = totalFrames(of: buffers, through: sut)

        // 48 kHz in, 16 kHz out: a third of the input frames. A converter
        // retired by .endOfStream after the first buffer produces a tenth of
        // this and nothing at all for the rest of the recording.
        let expected = buffers.reduce(0) { $0 + Int($1.frameLength) } / 3
        XCTAssertEqual(Double(produced), Double(expected), accuracy: Self.resamplerLatency)
    }

    func test_rebuilds_the_converter_when_the_input_format_changes() {
        let sut = ResamplingConverter(targetFormat: target)
        let before = (0..<5).map { _ in Self.tone(seconds: 0.1, in: Self.float32(sampleRate: 44_100)) }
        let after = (0..<5).map { _ in Self.tone(seconds: 0.1, in: Self.float32(sampleRate: 48_000)) }

        let producedBefore = totalFrames(of: before, through: sut)
        let producedAfter = totalFrames(of: after, through: sut)

        // Half a second each way, so 8_000 frames at 16 kHz regardless of the
        // input rate. A converter cached against the old format would fail or
        // resample by the wrong ratio.
        XCTAssertEqual(Double(producedBefore), 8_000, accuracy: Self.resamplerLatency)
        XCTAssertEqual(Double(producedAfter), 8_000, accuracy: Self.resamplerLatency)
    }

    func test_resumes_converting_after_a_reset() {
        let sut = ResamplingConverter(targetFormat: target)
        let input = Self.float32(sampleRate: 48_000)
        _ = sut.convert(Self.tone(seconds: 0.1, in: input))

        sut.reset()

        let buffers = (0..<10).map { _ in Self.tone(seconds: 0.1, in: input) }
        XCTAssertEqual(Double(totalFrames(of: buffers, through: sut)), 16_000, accuracy: Self.resamplerLatency)
    }
}
