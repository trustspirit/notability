import AVFoundation

/// Streams RMS values for fixed-size analysis blocks out of an audio file,
/// reading in larger chunks under the hood so memory stays bounded no matter
/// how long the file is. Once the file runs out of samples, every subsequent
/// call returns `nil` so the caller can treat "no more track" as silence.
final class BlockRMSReader {
    private let file: AVAudioFile
    private let blockFrames: Int
    private let readBuffer: AVAudioPCMBuffer
    private var pending: [Float] = []
    private var pendingOffset = 0
    private var fileExhausted = false

    init?(file: AVAudioFile, blockFrames: Int, chunkFrameCount: AVAudioFrameCount) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrameCount) else {
            return nil
        }
        self.file = file
        self.blockFrames = blockFrames
        self.readBuffer = buffer
    }

    /// The RMS of the next `blockFrames`-sized block (the final block may be
    /// shorter), or `nil` once the file has no samples left.
    func nextBlockRMS() throws -> Float? {
        while pending.count - pendingOffset < blockFrames, !fileExhausted {
            try fillPending()
        }

        let available = pending.count - pendingOffset
        guard available > 0 else { return nil }

        let count = min(blockFrames, available)
        var sum: Float = 0
        for index in pendingOffset..<(pendingOffset + count) {
            sum += pending[index] * pending[index]
        }
        pendingOffset += count
        compactIfNeeded()
        return sqrt(sum / Float(count))
    }

    private func fillPending() throws {
        // AVAudioFile.read(into:frameCount:) throws rather than returning
        // zero frames when called exactly at end-of-file, so the position
        // must be checked first (see AudioMixer's ChunkMixer for the same fix).
        guard file.framePosition < file.length else {
            fileExhausted = true
            return
        }
        try file.read(into: readBuffer, frameCount: readBuffer.frameCapacity)
        let framesRead = Int(readBuffer.frameLength)
        guard framesRead > 0 else {
            fileExhausted = true
            return
        }

        if let floats = readBuffer.floatChannelData {
            pending.append(contentsOf: UnsafeBufferPointer(start: floats[0], count: framesRead))
        } else if let ints = readBuffer.int16ChannelData {
            pending.append(contentsOf: (0..<framesRead).map { Float(ints[0][$0]) / 32_768 })
        }
    }

    private func compactIfNeeded() {
        guard pendingOffset > blockFrames * 4 else { return }
        pending.removeFirst(pendingOffset)
        pendingOffset = 0
    }
}
