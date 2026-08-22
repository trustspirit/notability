import AVFoundation

/// What the recording layer needs from a per-source audio writer.
///
/// `append` is called from realtime capture threads and must not block; see
/// `SessionRecorder` for the guarantees the real implementation makes, including
/// when `writeError` may be read.
///
/// `startTime` is the buffer's position on the shared capture timeline, not an
/// offset into this file. An implementation is responsible for making the two
/// the same, because the whole point of the shared timeline is that sample
/// index *n* means the same instant in every track.
protocol SessionAudioWriting: AnyObject {
    var url: URL { get }
    var writeError: Error? { get }
    func append(_ buffer: AVAudioPCMBuffer, startTime: TimeInterval)
    func finish()
}

/// Continuously records one capture source to an AAC file for the duration of a
/// meeting. Roughly 11 MB per hour at 24 kbps, which keeps a two-hour meeting
/// under the transcription API's 25 MB upload limit.
///
/// A buffer whose `startTime` is ahead of where the file has been written to is
/// preceded by exactly that much silence. Sources start at different moments
/// and can stop delivering mid-recording, and without the padding those
/// intervals would be cut out of the track rather than recorded as the gaps
/// they are, sliding everything after them earlier. Silence costs the AAC
/// bitrate like anything else — 3 KB per second — which for a start-up offset
/// or a device switch is a few tens of kilobytes.
final class SessionRecorder: SessionAudioWriting {
    let url: URL

    /// Set when the first on-disk write fails. Meeting audio is kept until note
    /// generation succeeds so a failed run can be retried; without surfacing write
    /// failures the file would be silently truncated and downstream transcription
    /// would produce an incomplete transcript with no indication to retry.
    ///
    /// Only valid once `finish()` has returned. It is written on the writer queue
    /// and this accessor is unsynchronized, so reading it mid-recording races that
    /// thread; `finish()` drains the queue, which is what makes the read safe.
    /// Surfacing failures during a recording would need a lock, not just a read.
    private(set) var writeError: Error?

    private var file: AVAudioFile?
    private let sampleRate: Double
    /// Frames on disk, padding included, so the next buffer knows how far the
    /// file already reaches. Only ever touched on `queue`.
    private var framesWritten: AVAudioFramePosition = 0
    private var silence: AVAudioPCMBuffer?
    private let queue = DispatchQueue(label: "com.notability.sessionrecorder", qos: .utility)

    /// Padding is written in chunks so that a long gap costs a bounded buffer
    /// rather than one allocation the size of the gap.
    private static let silenceChunkFrames: AVAudioFrameCount = 16_384

    init(directory: URL, source: AudioSource, sampleRate: Double) throws {
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(source.fileBaseName).m4a")
        try? FileManager.default.removeItem(at: url)
        // commonFormat/interleaved declare the *processing* format the caller writes in
        // (Int16, matching the 16 kHz mono capture format); the file itself still
        // encodes to AAC per `settings`. Without this, AVAudioFile defaults its
        // processing format to Float32 and `append` throws on the Int16 buffers
        // the capture layer hands us.
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        guard buffer.frameLength > 0 else { return }
        let startFrame = AVAudioFramePosition((startTime * sampleRate).rounded())
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            do {
                try self.padSilence(upTo: startFrame, in: file)
                try file.write(from: buffer)
                self.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                if self.writeError == nil {
                    self.writeError = error
                }
            }
        }
    }

    /// Extends the file with silence until it reaches `startFrame`.
    ///
    /// Does nothing when the file is already there, which is the ordinary case:
    /// timestamps advance by delivered frames, so only a source's first buffer
    /// and a buffer following a capture interruption find a gap ahead of them.
    private func padSilence(upTo startFrame: AVAudioFramePosition, in file: AVAudioFile) throws {
        var missing = startFrame - framesWritten
        guard missing > 0 else { return }

        let buffer = try silenceBuffer(matching: file)
        while missing > 0 {
            let chunk = AVAudioFrameCount(min(missing, AVAudioFramePosition(Self.silenceChunkFrames)))
            buffer.frameLength = chunk
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(chunk)
            missing -= AVAudioFramePosition(chunk)
        }
    }

    /// A zeroed scratch buffer in the file's processing format, allocated once
    /// and reused. `AVAudioPCMBuffer` does not promise zeroed storage, so it is
    /// cleared here rather than assumed.
    private func silenceBuffer(matching file: AVAudioFile) throws -> AVAudioPCMBuffer {
        if let silence { return silence }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: Self.silenceChunkFrames
        ) else {
            throw RecorderError.silenceBufferUnavailable
        }
        // `mDataByteSize` follows `frameLength`, not capacity, so the whole
        // allocation is only reachable once the length covers it.
        buffer.frameLength = Self.silenceChunkFrames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            memset(channel.mData, 0, Int(channel.mDataByteSize))
        }
        silence = buffer
        return buffer
    }

    /// Flushes pending writes and closes the file. Appends after this are dropped.
    func finish() {
        queue.sync {
            // Releasing the AVAudioFile is what finalises the container.
            file = nil
            silence = nil
        }
    }

    enum RecorderError: Error, LocalizedError {
        case silenceBufferUnavailable

        var errorDescription: String? {
            "Could not allocate the buffer used to keep the recording's tracks aligned."
        }
    }
}
