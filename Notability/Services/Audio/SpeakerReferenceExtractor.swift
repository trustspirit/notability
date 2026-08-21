import AVFoundation

/// Finds a stretch of audio where only the local speaker is talking, so it can
/// be sent as a `known_speaker_references` sample. With that reference the
/// diarization model labels the user's turns directly instead of assigning them
/// an anonymous letter.
///
/// Both tracks are read in bounded chunks rather than decoded whole, and
/// scanning stops the instant a qualifying window is found — a two-hour
/// meeting where the user speaks alone in the first ten seconds never touches
/// the rest of either file.
enum SpeakerReferenceExtractor {
    struct Config {
        var windowDuration: TimeInterval = 10
        var analysisWindow: TimeInterval = 0.02
        var speechRMSThreshold: Float = 0.005
        var silenceRMSThreshold: Float = 0.002
        var minimumSpeechFrameRatio: Float = 0.7

        init() {}
    }

    private static let chunkFrameCount: AVAudioFrameCount = 16_384

    static func extract(
        micURL: URL,
        systemURL: URL?,
        config: Config = Config()
    ) throws -> Data? {
        let micFile = try AVAudioFile(forReading: micURL)
        let sampleRate = micFile.processingFormat.sampleRate
        let windowFrames = Int(config.windowDuration * sampleRate)
        guard micFile.length >= AVAudioFramePosition(windowFrames) else { return nil }

        let blockFrames = max(1, Int(config.analysisWindow * sampleRate))
        let blocksPerWindow = max(1, windowFrames / blockFrames)

        guard let micReader = BlockRMSReader(file: micFile, blockFrames: blockFrames, chunkFrameCount: chunkFrameCount) else {
            return nil
        }
        let systemFile = systemURL.flatMap { try? AVAudioFile(forReading: $0) }
        let systemReader = systemFile.flatMap {
            BlockRMSReader(file: $0, blockFrames: blockFrames, chunkFrameCount: chunkFrameCount)
        }

        var scanner = WindowScanner(blocksPerWindow: blocksPerWindow, config: config)

        while let micRMS = try micReader.nextBlockRMS() {
            // A missing, exhausted, or shorter system track has no more
            // audio to leak into the mic, so treat it as silence.
            let systemRMS = try systemReader?.nextBlockRMS() ?? 0

            if let matchStart = scanner.push(micRMS: micRMS, systemRMS: systemRMS) {
                return try extractWindow(
                    micURL: micURL,
                    frameStart: matchStart * blockFrames,
                    windowFrames: windowFrames,
                    sampleRate: sampleRate
                )
            }
        }

        return nil
    }

    /// Re-opens the track as Int16 instead of reusing the file the scan read
    /// from. The clip ships as 16-bit PCM, so letting AVAudioFile do that
    /// conversion once avoids a lossy round-trip through Float, and the
    /// scanning file keeps its own read position.
    private static func extractWindow(
        micURL: URL,
        frameStart: Int,
        windowFrames: Int,
        sampleRate: Double
    ) throws -> Data? {
        let file = try AVAudioFile(forReading: micURL, commonFormat: .pcmFormatInt16, interleaved: false)
        let framesToRead = min(windowFrames, Int(file.length) - frameStart)
        guard framesToRead > 0 else { return nil }

        let samples = try readSamples(from: file, frameStart: frameStart, frameCount: framesToRead)
        guard !samples.isEmpty else { return nil }
        return try wavData(from: samples, sampleRate: sampleRate)
    }

    private static func readSamples(
        from file: AVAudioFile,
        frameStart: Int,
        frameCount: Int
    ) throws -> [Int16] {
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return []
        }
        file.framePosition = AVAudioFramePosition(frameStart)

        var samples: [Int16] = []
        samples.reserveCapacity(frameCount)
        // A single read stops on an internal buffer boundary rather than
        // filling the request, so a ten-second window needs several passes.
        while samples.count < frameCount, file.framePosition < file.length {
            try file.read(into: scratch, frameCount: AVAudioFrameCount(frameCount - samples.count))
            guard scratch.frameLength > 0, let channel = scratch.int16ChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(scratch.frameLength)))
        }
        return samples
    }

    private static func wavData(from samples: [Int16], sampleRate: Double) throws -> Data? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Writing must happen in its own scope: a WAV header's frame count is
        // only finalized when the writer's AVAudioFile is deallocated, so
        // reading the bytes back has to wait until after that happens.
        try writeWAV(buffer, format: format, to: url)
        return try Data(contentsOf: url)
    }

    private static func writeWAV(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

/// Streams RMS values for fixed-size analysis blocks out of an audio file,
/// reading in larger chunks under the hood so memory stays bounded no matter
/// how long the file is. Once the file runs out of samples, every subsequent
/// call returns `nil` so the caller can treat "no more track" as silence.
private final class BlockRMSReader {
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

/// Tracks the most recent `blocksPerWindow` analysis blocks for both tracks in
/// fixed-size rings, recognising a qualifying window in O(1) per block instead
/// of rescanning history on every new block.
private struct WindowScanner {
    private let blocksPerWindow: Int
    private let config: SpeakerReferenceExtractor.Config
    private var isSpeechRing: [Bool]
    private var isQuietRing: [Bool]
    private var writeIndex = 0
    private var blocksSeen = 0
    private var speechCount = 0
    private var quietCount = 0

    init(blocksPerWindow: Int, config: SpeakerReferenceExtractor.Config) {
        self.blocksPerWindow = blocksPerWindow
        self.config = config
        self.isSpeechRing = [Bool](repeating: false, count: blocksPerWindow)
        self.isQuietRing = [Bool](repeating: false, count: blocksPerWindow)
    }

    /// Feeds one new block's RMS values. Returns the starting block index of a
    /// qualifying window the moment its last block arrives — i.e. the first
    /// qualifying window, scanning forward from the start.
    mutating func push(micRMS: Float, systemRMS: Float) -> Int? {
        let isSpeech = micRMS >= config.speechRMSThreshold
        let isQuiet = systemRMS < config.silenceRMSThreshold

        if blocksSeen >= blocksPerWindow {
            if isSpeechRing[writeIndex] { speechCount -= 1 }
            if isQuietRing[writeIndex] { quietCount -= 1 }
        }
        isSpeechRing[writeIndex] = isSpeech
        isQuietRing[writeIndex] = isQuiet
        if isSpeech { speechCount += 1 }
        if isQuiet { quietCount += 1 }

        writeIndex = (writeIndex + 1) % blocksPerWindow
        blocksSeen += 1

        guard blocksSeen >= blocksPerWindow else { return nil }
        guard quietCount == blocksPerWindow else { return nil }

        let ratio = Float(speechCount) / Float(blocksPerWindow)
        guard ratio >= config.minimumSpeechFrameRatio else { return nil }

        return blocksSeen - blocksPerWindow
    }
}
