import ScreenCaptureKit
import AVFoundation
import Combine

final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol, SCStreamOutput, SCStreamDelegate {
    private var subject = PassthroughSubject<(url: URL, timestamp: TimeInterval), Never>()
    var chunkPublisher: AnyPublisher<(url: URL, timestamp: TimeInterval), Never> {
        subject.eraseToAnyPublisher()
    }

    private let levelSubject = PassthroughSubject<Float, Never>()
    var audioLevelPublisher: AnyPublisher<Float, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    private var stream: SCStream?
    private let chunker: AudioChunker
    private var startDate: Date?
    // Separate converters per source type to avoid recreation on alternating .audio/.microphone buffers
    private var cachedAudioConverter: AVAudioConverter?
    private var cachedMicConverter: AVAudioConverter?

    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(chunker: AudioChunker = AudioChunker()) {
        self.chunker = chunker
        super.init()
        self.chunker.onChunk = { [weak self] url, ts in
            self?.subject.send((url: url, timestamp: ts))
        }
    }

    func startCapture() async throws {
        // Clean up any lingering stream from a previous session
        if let existing = stream {
            try? await existing.stopCapture()
            stream = nil
        }
        cachedAudioConverter = nil
        cachedMicConverter = nil
        // Fresh subject for each session — the previous one was completed by stopCapture().
        subject = PassthroughSubject()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("[AudioCaptureService] SCShareableContent failed: \(error)")
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        // Minimize video capture (audio-only focus)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        if #available(macOS 15.0, *) {
            // captureMicrophone delivers user's voice via a SEPARATE .microphone output type —
            // it is NOT mixed into .audio. Without this subscription the mic is silently ignored.
            try stream?.addStreamOutput(self, type: .microphone, sampleHandlerQueue: .global(qos: .userInitiated))
        }
        do {
            try await stream?.startCapture()
        } catch {
            stream = nil
            print("[AudioCaptureService] startCapture failed: \(error)")
            throw CaptureError.streamFailed(error)
        }
        startDate = Date()
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            print("[AudioCaptureService] Stream stop error: \(error)")
        }
        stream = nil
        // flush() is synchronous — final chunk is sent before completion fires.
        chunker.flush()
        subject.send(completion: .finished)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let isMicrophone: Bool
        if #available(macOS 15.0, *) {
            guard type == .audio || type == .microphone else { return }
            isMicrophone = (type == .microphone)
        } else {
            guard type == .audio else { return }
            isMicrophone = false
        }

        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList)

        // Use separate cached converters for system audio vs microphone to avoid
        // recreating the converter on every alternating buffer.
        if isMicrophone {
            if cachedMicConverter == nil || !cachedMicConverter!.inputFormat.isEqual(srcFormat) {
                cachedMicConverter = AVAudioConverter(from: srcFormat, to: captureFormat)
            }
        } else {
            if cachedAudioConverter == nil || !cachedAudioConverter!.inputFormat.isEqual(srcFormat) {
                cachedAudioConverter = AVAudioConverter(from: srcFormat, to: captureFormat)
            }
        }
        guard let converter = isMicrophone ? cachedMicConverter : cachedAudioConverter,
              let dstBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if error == nil, dstBuffer.frameLength > 0 {
            let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
            chunker.append(dstBuffer, timestamp: elapsed)
            // Use mic level for waveform when available — it reflects the user's voice
            if isMicrophone { levelSubject.send(computeRMS(dstBuffer)) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        chunker.flush()
        subject.send(completion: .finished)
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let s = Float(data[i]) / 32_768.0
            sum += s * s
        }
        return sqrt(sum / Float(buffer.frameLength))
    }

    enum CaptureError: Error {
        case noDisplay
        case permissionDenied
        case streamFailed(Error)
    }
}
