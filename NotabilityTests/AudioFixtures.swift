import AVFoundation
@testable import Notability

/// Stands in for the monotonic clock `CaptureBufferRelay` derives its shared
/// origin from, so a test can place a source's first buffer at an exact instant
/// instead of waiting for real capture to deliver one.
final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    var read: CaptureBufferRelay.MonotonicClock {
        { [self] in lock.withLock { seconds } }
    }

    var now: TimeInterval { lock.withLock { seconds } }

    func advance(by interval: TimeInterval) {
        lock.withLock { seconds += interval }
    }

    func set(to instant: TimeInterval) {
        lock.withLock { seconds = instant }
    }
}

enum AudioFixtures {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// A 440 Hz sine at the given amplitude (0...1).
    static func tone(seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        buffer(seconds: seconds) { index in
            amplitude * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
    }

    static func silence(seconds: Double) -> AVAudioPCMBuffer {
        buffer(seconds: seconds) { _ in 0 }
    }

    static func buffer(seconds: Double, sample: (Int) -> Float) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.int16ChannelData![0]
        for index in 0..<Int(frames) {
            let value = max(-1, min(1, sample(index)))
            channel[index] = Int16(value * 32_767)
        }
        return buffer
    }

    /// Writes a buffer to a 16 kHz mono WAV file and returns its URL.
    static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// AAC at the settings `SessionRecorder` writes with, so a fixture track is
    /// the same kind of file the recording layer produces.
    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 24_000
    ]

    /// Writes a track file whose container is complete, the way `finish()`
    /// leaves it. The `AVAudioFile` is released before this returns, which is
    /// what completes it.
    static func writeTrack(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: aacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Writes a track file whose container was never completed — what a process
    /// that dies with the `AVAudioFile` still open leaves on disk.
    ///
    /// A test cannot kill its own process to produce the real thing, so this
    /// reproduces the byte layout one leaves: `ftyp` followed by a zeroed
    /// placeholder where the `moov` atom belongs. The sample data is all
    /// present; the index that makes it decodable is not, which is why no
    /// decoder will open the result.
    static func writeUnfinalizedTrack(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        try writeTrack(buffer, to: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        guard let header = moovHeaderRange(in: bytes) else {
            throw FixtureError.moovAtomNotFound
        }
        for index in header { bytes[index] = 0 }
        try Data(bytes).write(to: url)
    }

    /// A track file that opens and reports no audio in it: written and closed
    /// without a single frame, which is what a source that never delivered a
    /// buffer leaves behind.
    static func writeEmptyTrack(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        _ = try AVAudioFile(
            forWriting: url,
            settings: aacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
    }

    enum FixtureError: Error {
        case moovAtomNotFound
    }

    /// The eight header bytes — big-endian size, then the four-character name —
    /// of the top-level `moov` atom.
    private static func moovHeaderRange(in bytes: [UInt8]) -> Range<Int>? {
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self) == "moov" {
                return offset..<(offset + 8)
            }
            guard size >= 8 else { return nil }
            offset += size
        }
        return nil
    }

    /// Root-mean-square amplitude of a file, normalised to 0...1.
    static func rms(ofFileAt url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { return 0 }

        var sum: Float = 0
        if let floats = buffer.floatChannelData {
            for index in 0..<Int(buffer.frameLength) {
                let value = floats[0][index]
                sum += value * value
            }
        } else if let ints = buffer.int16ChannelData {
            for index in 0..<Int(buffer.frameLength) {
                let value = Float(ints[0][index]) / 32_768
                sum += value * value
            }
        }
        return sqrt(sum / Float(buffer.frameLength))
    }
}
