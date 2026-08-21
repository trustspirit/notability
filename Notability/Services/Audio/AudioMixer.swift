import AVFoundation

enum AudioMixerError: Error, LocalizedError {
    case noTracks
    case unreadableTrack(URL)

    var errorDescription: String? {
        switch self {
        case .noTracks:
            return "No audio tracks were available to mix."
        case .unreadableTrack(let url):
            return "Could not read the audio track at \(url.lastPathComponent)."
        }
    }
}

/// Sums capture tracks onto a single timeline. Both tracks start at the same
/// instant and carry frame-derived timestamps, so aligning by sample index is
/// sufficient — no drift correction is needed.
///
/// Tracks are read and written in fixed-size chunks rather than decoded whole,
/// so mixing a multi-hour meeting never holds a full track in memory.
enum AudioMixer {
    private static let chunkFrameCount: AVAudioFrameCount = 16_384

    static func mix(tracks: [URL], to outputURL: URL, gain: Float = 0.5) throws {
        guard !tracks.isEmpty else { throw AudioMixerError.noTracks }

        var readers: [AVAudioFile] = []
        for track in tracks {
            guard let file = try? AVAudioFile(forReading: track) else {
                throw AudioMixerError.unreadableTrack(track)
            }
            readers.append(file)
        }

        let sampleRate = readers[0].processingFormat.sampleRate
        let totalFrames = readers.map(\.length).max() ?? 0
        guard totalFrames > 0 else { throw AudioMixerError.noTracks }

        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let mixBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrameCount) else {
            throw AudioMixerError.noTracks
        }

        var readBuffers: [AVAudioPCMBuffer] = []
        for (index, file) in readers.enumerated() {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: chunkFrameCount
            ) else {
                throw AudioMixerError.unreadableTrack(tracks[index])
            }
            readBuffers.append(buffer)
        }

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000
        ])

        let mixChannel = mixBuffer.floatChannelData![0]
        var exhausted = [Bool](repeating: false, count: readers.count)
        var framesRemaining = Int(totalFrames)

        while framesRemaining > 0 {
            let framesToWrite = min(Int(chunkFrameCount), framesRemaining)
            for index in 0..<framesToWrite { mixChannel[index] = 0 }

            for trackIndex in 0..<readers.count {
                guard !exhausted[trackIndex] else { continue }
                let file = readers[trackIndex]
                let readBuffer = readBuffers[trackIndex]
                try file.read(into: readBuffer, frameCount: AVAudioFrameCount(framesToWrite))
                let framesRead = Int(readBuffer.frameLength)
                guard framesRead > 0 else {
                    exhausted[trackIndex] = true
                    continue
                }

                if let floats = readBuffer.floatChannelData {
                    for index in 0..<framesRead {
                        mixChannel[index] += floats[0][index] * gain
                    }
                } else if let ints = readBuffer.int16ChannelData {
                    for index in 0..<framesRead {
                        mixChannel[index] += (Float(ints[0][index]) / 32_768) * gain
                    }
                } else {
                    throw AudioMixerError.unreadableTrack(tracks[trackIndex])
                }

                if framesRead < framesToWrite {
                    exhausted[trackIndex] = true
                }
            }

            for index in 0..<framesToWrite {
                mixChannel[index] = max(-1, min(1, mixChannel[index]))
            }
            mixBuffer.frameLength = AVAudioFrameCount(framesToWrite)
            try outputFile.write(from: mixBuffer)

            framesRemaining -= framesToWrite
        }
    }
}
