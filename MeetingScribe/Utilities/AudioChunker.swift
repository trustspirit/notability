// MeetingScribe/Utilities/AudioChunker.swift
import AVFoundation

final class AudioChunker {
    var onChunk: ((URL, TimeInterval) -> Void)?

    private let chunkDuration: Double
    private let outputDirectory: URL
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private var accumulatedBuffers: [AVAudioPCMBuffer] = []
    private var accumulatedFrames: AVAudioFrameCount = 0
    private var chunkStartTimestamp: TimeInterval = 0
    private var isFirstBuffer = true
    private let samplesPerChunk: AVAudioFrameCount

    init(chunkDuration: Double = 30, outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.chunkDuration = chunkDuration
        self.outputDirectory = outputDirectory
        self.samplesPerChunk = AVAudioFrameCount(16000 * chunkDuration)
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        if isFirstBuffer {
            chunkStartTimestamp = timestamp
            isFirstBuffer = false
        }
        accumulatedBuffers.append(buffer)
        accumulatedFrames += buffer.frameLength

        if accumulatedFrames > samplesPerChunk {
            emitChunk()
        }
    }

    func flush() {
        guard accumulatedFrames > 0 else { return }
        emitChunk()
    }

    private func emitChunk() {
        guard !accumulatedBuffers.isEmpty else { return }
        let url = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: false) {
            for buf in accumulatedBuffers {
                try? file.write(from: buf)
            }
        }
        let ts = chunkStartTimestamp
        accumulatedBuffers = []
        accumulatedFrames = 0
        isFirstBuffer = true
        onChunk?(url, ts)
    }
}
