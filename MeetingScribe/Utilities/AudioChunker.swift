import AVFoundation

final class AudioChunker {
    var onChunk: ((URL, TimeInterval) -> Void)?

    private let outputDirectory: URL
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private var accumulatedBuffers: [AVAudioPCMBuffer] = []
    private var accumulatedFrames: AVAudioFrameCount = 0
    private var consecutiveSilentFrames: AVAudioFrameCount = 0
    private var chunkStartTimestamp: TimeInterval = 0
    private var isFirstBuffer = true
    private let queue = DispatchQueue(label: "com.meetingscribe.audiochunker", qos: .userInitiated)

    // Emit when silence lasts this long AND minimum chunk duration is met.
    // 0.6 s of quiet = natural sentence/breath boundary.
    private static let sentenceBoundaryDuration: Double = 0.6
    private static let minChunkDuration: Double = 2.0   // avoid tiny fragments

    // Silence threshold for per-buffer boundary detection (slightly above background hiss).
    private static let boundaryThreshold: Float = 0.003
    // Whole-chunk threshold: filter chunks that are entirely near-silent.
    private static let silenceThreshold: Float = 0.001

    // Fallback max duration — emit even without a silence boundary (non-stop speech).
    // Exposed as init parameter for testability.
    private let maxChunkDuration: Double

    init(chunkDuration: Double = 30.0,
         outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.maxChunkDuration = chunkDuration
        self.outputDirectory = outputDirectory
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        queue.async { [self] in _append(buffer, timestamp: timestamp) }
    }

    func flush() {
        queue.sync { [self] in _flush() }
    }

    private func _append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        if isFirstBuffer {
            chunkStartTimestamp = timestamp
            isFirstBuffer = false
        }
        accumulatedBuffers.append(buffer)
        accumulatedFrames += buffer.frameLength

        // Track consecutive silence frames for sentence boundary detection.
        if rmsOf(buffer) < Self.boundaryThreshold {
            consecutiveSilentFrames += buffer.frameLength
        } else {
            consecutiveSilentFrames = 0
        }

        let sr = AVAudioFrameCount(16000)
        let minFrames   = AVAudioFrameCount(Double(sr) * Self.minChunkDuration)
        let boundFrames = AVAudioFrameCount(Double(sr) * Self.sentenceBoundaryDuration)
        let maxFrames   = AVAudioFrameCount(Double(sr) * maxChunkDuration)

        if accumulatedFrames >= minFrames && consecutiveSilentFrames >= boundFrames {
            // Natural sentence boundary detected.
            _emitChunk()
        } else if accumulatedFrames >= maxFrames {
            // Fallback: speaker never paused — emit at max duration.
            _emitChunk()
        }
    }

    private func _flush() {
        guard accumulatedFrames > 0 else { return }
        _emitChunk()
    }

    private func _emitChunk() {
        guard !accumulatedBuffers.isEmpty else { return }
        // Drop chunks that are entirely near-silent (background noise, no speech).
        guard rms() > Self.silenceThreshold else {
            resetState()
            return
        }
        let url = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: false)
            for buf in accumulatedBuffers { try file.write(from: buf) }
        } catch {
            print("[AudioChunker] Failed to write WAV chunk: \(error)")
            resetState()
            return
        }
        let ts = chunkStartTimestamp
        resetState()
        onChunk?(url, ts)
    }

    private func resetState() {
        accumulatedBuffers = []
        accumulatedFrames = 0
        consecutiveSilentFrames = 0
        isFirstBuffer = true
    }

    // Per-buffer RMS — used for sentence boundary detection.
    private func rmsOf(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let s = Float(data[i]) / 32_768.0
            sum += s * s
        }
        return sqrt(sum / Float(buffer.frameLength))
    }

    // Whole-chunk peak RMS over 1-second windows — used to filter silent chunks.
    private func rms() -> Float {
        let windowSize: Int = 16000
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
