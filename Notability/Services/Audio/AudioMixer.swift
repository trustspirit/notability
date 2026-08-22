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

/// Sums capture tracks onto a single timeline by sample index, with no drift
/// correction.
///
/// That is sufficient because the capture layer has already done the aligning:
/// every buffer is stamped against one origin shared by both sources, and
/// `SessionRecorder` pads each track with silence up to its buffers' start
/// times. So frame *n* of `mic.m4a` and frame *n* of `system.m4a` are the same
/// instant of the meeting, however far apart the two sources started.
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
    /// ready to write. A track that has run out is treated as silence for
    /// the rest of the mix.
    mutating func mixChunk(frameCount: Int) throws -> AVAudioPCMBuffer {
        for index in 0..<frameCount { mixChannel[index] = 0 }

        for trackIndex in 0..<readers.count where !exhausted[trackIndex] {
            try sumTrack(trackIndex, frameCount: frameCount)
        }

        for index in 0..<frameCount {
            mixChannel[index] = max(-1, min(1, mixChannel[index]))
        }
        mixBuffer.frameLength = AVAudioFrameCount(frameCount)
        return mixBuffer
    }

    private mutating func sumTrack(_ trackIndex: Int, frameCount: Int) throws {
        let file = readers[trackIndex]
        let readBuffer = readBuffers[trackIndex]
        var offset = 0

        while offset < frameCount {
            // AVAudioFile.read(into:frameCount:) throws rather than returning
            // zero frames when called exactly at end-of-file, which happens
            // whenever a track's length is a multiple of the chunk size. Check
            // the position first so that case is silence, not a thrown error.
            guard file.framePosition < file.length else {
                exhausted[trackIndex] = true
                return
            }
            // A read can also stop on an internal buffer boundary short of the
            // requested count while the track still has audio left, so a short
            // read is not by itself the end of the track.
            try file.read(into: readBuffer, frameCount: AVAudioFrameCount(frameCount - offset))
            let framesRead = Int(readBuffer.frameLength)
            guard framesRead > 0 else {
                exhausted[trackIndex] = true
                return
            }

            if let floats = readBuffer.floatChannelData {
                for index in 0..<framesRead {
                    mixChannel[offset + index] += floats[0][index] * gain
                }
            } else if let ints = readBuffer.int16ChannelData {
                for index in 0..<framesRead {
                    mixChannel[offset + index] += (Float(ints[0][index]) / 32_768) * gain
                }
            } else {
                throw AudioMixerError.unreadableTrack(tracks[trackIndex])
            }
            offset += framesRead
        }
    }
}
