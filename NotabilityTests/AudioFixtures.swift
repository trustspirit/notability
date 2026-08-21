import AVFoundation

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
