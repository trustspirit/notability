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

        let readers = try openReaders(for: tracks)
        let sampleRate = readers[0].processingFormat.sampleRate
        let totalFrames = readers.map(\.length).max() ?? 0
        guard totalFrames > 0 else { throw AudioMixerError.noTracks }

        var mixer = try ChunkMixer(tracks: tracks, readers: readers, sampleRate: sampleRate, gain: gain, chunkFrameCount: chunkFrameCount)

        // Everything from here on writes to outputURL. If any of it throws,
        // the caller must not find a truncated file where the mix should be.
        do {
            let outputFile = try makeOutputFile(at: outputURL, sampleRate: sampleRate)
            var framesRemaining = Int(totalFrames)
            while framesRemaining > 0 {
                let framesToWrite = min(Int(chunkFrameCount), framesRemaining)
                let chunk = try mixer.mixChunk(frameCount: framesToWrite)
                try outputFile.write(from: chunk)
                framesRemaining -= framesToWrite
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func openReaders(for tracks: [URL]) throws -> [AVAudioFile] {
        var readers: [AVAudioFile] = []
        for track in tracks {
            guard let file = try? AVAudioFile(forReading: track) else {
                throw AudioMixerError.unreadableTrack(track)
            }
            readers.append(file)
        }
        return readers
    }

    private static func makeOutputFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        try? FileManager.default.removeItem(at: url)
        return try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000
        ])
    }
}

/// Owns the per-track read state for one mix: readers, their scratch read
/// buffers, which tracks have run out, and the buffer the current chunk is
/// summed into. Bundling these together means the outer chunk loop only has
/// to track how many frames are left, not the mixing internals.
private struct ChunkMixer {
    private let tracks: [URL]
    private let readers: [AVAudioFile]
    private let readBuffers: [AVAudioPCMBuffer]
    private let mixBuffer: AVAudioPCMBuffer
    private let mixChannel: UnsafeMutablePointer<Float>
    private let gain: Float
    private var exhausted: [Bool]

    init(tracks: [URL], readers: [AVAudioFile], sampleRate: Double, gain: Float, chunkFrameCount: AVAudioFrameCount) throws {
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

        self.tracks = tracks
        self.readers = readers
        self.readBuffers = readBuffers
        self.mixBuffer = mixBuffer
        self.mixChannel = mixBuffer.floatChannelData![0]
        self.gain = gain
        self.exhausted = [Bool](repeating: false, count: readers.count)
    }

    /// Reads up to `frameCount` frames from every unexhausted track, sums
    /// them with `gain` applied, clamps to [-1, 1], and returns the result
    /// ready to write. A track that returns fewer frames than requested —
    /// including zero, when its length is an exact multiple of the chunk
    /// size — is marked exhausted and treated as silence for the rest of
    /// the mix.
    mutating func mixChunk(frameCount: Int) throws -> AVAudioPCMBuffer {
        for index in 0..<frameCount { mixChannel[index] = 0 }

        for trackIndex in 0..<readers.count {
            guard !exhausted[trackIndex] else { continue }
            let file = readers[trackIndex]
            // AVAudioFile.read(into:frameCount:) throws rather than returning
            // zero frames when called exactly at end-of-file, which happens
            // whenever a track's length is a multiple of the chunk size. Check
            // the position first so that case is silence, not a thrown error.
            guard file.framePosition < file.length else {
                exhausted[trackIndex] = true
                continue
            }
            let readBuffer = readBuffers[trackIndex]
            try file.read(into: readBuffer, frameCount: AVAudioFrameCount(frameCount))
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

            if framesRead < frameCount {
                exhausted[trackIndex] = true
            }
        }

        for index in 0..<frameCount {
            mixChannel[index] = max(-1, min(1, mixChannel[index]))
        }
        mixBuffer.frameLength = AVAudioFrameCount(frameCount)
        return mixBuffer
    }
}
