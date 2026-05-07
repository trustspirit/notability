import ScreenCaptureKit
import AVFoundation
import Combine

final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol, SCStreamOutput, SCStreamDelegate {
    private let subject = PassthroughSubject<(url: URL, timestamp: TimeInterval), Never>()
    var chunkPublisher: AnyPublisher<(url: URL, timestamp: TimeInterval), Never> {
        subject.eraseToAnyPublisher()
    }

    private var stream: SCStream?
    private let chunker: AudioChunker
    private var startDate: Date?
    private var cachedConverter: AVAudioConverter?

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
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimize video capture (audio-only focus)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        do {
            try await stream?.startCapture()
        } catch {
            stream = nil
            throw error
        }
        startDate = Date()
    }

    func stopCapture() {
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                print("[AudioCaptureService] Stream stop error: \(error)")
            }
            stream = nil
            chunker.flush()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList)

        // Reuse converter as long as source format hasn't changed
        if cachedConverter == nil || !(cachedConverter!.inputFormat.isEqual(srcFormat)) {
            cachedConverter = AVAudioConverter(from: srcFormat, to: captureFormat)
        }
        guard let converter = cachedConverter,
              let dstBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if error == nil {
            let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
            chunker.append(dstBuffer, timestamp: elapsed)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        chunker.flush()
    }

    enum CaptureError: Error {
        case noDisplay
    }
}
