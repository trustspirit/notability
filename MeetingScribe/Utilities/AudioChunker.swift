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
    private let queue = DispatchQueue(label: "com.meetingscribe.audiochunker", qos: .userInitiated)

    init(chunkDuration: Double = 30, outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.chunkDuration = chunkDuration
        self.outputDirectory = outputDirectory
        self.samplesPerChunk = AVAudioFrameCount(16000 * chunkDuration)
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        queue.async { [self] in
            _append(buffer, timestamp: timestamp)
        }
    }

    func flush() {
        queue.sync { [self] in
            _flush()
        }
    }

    private func _append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        if isFirstBuffer {
            chunkStartTimestamp = timestamp
            isFirstBuffer = false
        }
        accumulatedBuffers.append(buffer)
        accumulatedFrames += buffer.frameLength

        if accumulatedFrames >= samplesPerChunk {
            _emitChunk()
        }
    }

    private func _flush() {
        guard accumulatedFrames > 0 else { return }
        _emitChunk()
    }

    // Peak RMS threshold per 1-second window; chunks below this are silent.
    // 0.001 ≈ -60 dBFS catches near-silent speech while still dropping pure hiss.
    private static let silenceThreshold: Float = 0.001

    private func _emitChunk() {
        guard !accumulatedBuffers.isEmpty else { return }
        guard rms() > Self.silenceThreshold else {
            accumulatedBuffers = []
            accumulatedFrames = 0
            isFirstBuffer = true
            return
        }
        let url = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: false)
            for buf in accumulatedBuffers {
                try file.write(from: buf)
            }
        } catch {
            print("[AudioChunker] Failed to write WAV chunk: \(error)")
            accumulatedBuffers = []
            accumulatedFrames = 0
            isFirstBuffer = true
            return  // do NOT call onChunk with a broken file
        }
        let ts = chunkStartTimestamp
        accumulatedBuffers = []
        accumulatedFrames = 0
        isFirstBuffer = true
        onChunk?(url, ts)
    }

    // Returns the peak RMS over 1-second windows instead of average over the whole chunk.
    // Averaging over 30 seconds drops below threshold even for clear speech with silences —
    // e.g. 5 seconds of speech in a 30-second chunk gives only ~41% of the actual speech RMS.
    private func rms() -> Float {
        let windowSize: Int = 16000 // 1 second at 16 kHz
        var windowSum: Float = 0
        var windowCount = 0
        var peakRMS: Float = 0

        for buf in accumulatedBuffers {
            guard let data = buf.int16ChannelData?[0] else { continue }
            for i in 0..<Int(buf.frameLength) {
                let s = Float(data[i]) / 32_768.0
                windowSum += s * s
                windowCount += 1
                if windowCount >= windowSize {
                    peakRMS = max(peakRMS, sqrt(windowSum / Float(windowCount)))
                    windowSum = 0
                    windowCount = 0
                }
            }
        }
        if windowCount > 0 {
            peakRMS = max(peakRMS, sqrt(windowSum / Float(windowCount)))
        }
        return peakRMS
    }
}
