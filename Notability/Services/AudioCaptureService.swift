import ScreenCaptureKit
import AVFoundation
import Combine

final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol,
                                  SCStreamOutput, SCStreamDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {

    private var subject = PassthroughSubject<AudioChunk, Never>()
    var chunkPublisher: AnyPublisher<AudioChunk, Never> {
        subject.eraseToAnyPublisher()
    }

    private let levelSubject = PassthroughSubject<Float, Never>()
    var audioLevelPublisher: AnyPublisher<Float, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    private let systemAudioAvailabilitySubject = CurrentValueSubject<Bool, Never>(false)
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> {
        systemAudioAvailabilitySubject.eraseToAnyPublisher()
    }

    private(set) var isCapturingSystemAudio = false {
        didSet {
            guard oldValue != isCapturingSystemAudio else { return }
            systemAudioAvailabilitySubject.send(isCapturingSystemAudio)
        }
    }
    private(set) var isCapturingMicrophone = false
    // Guards processBuffer after stopCapture() — prevents post-stopRunning callbacks
    // from appending to chunkers after flush() has already been called.
    private var isCapturing = false

    private var stream: SCStream?
    private var captureSession: AVCaptureSession?
    private var startDate: Date?

    private let systemAudioChunker = AudioChunker()
    // Microphone RMS is typically lower than system audio, so use relaxed thresholds.
    // boundaryThreshold sits above the mic noise floor (~0.002) so background hiss
    // doesn't prevent silence detection and natural chunk boundaries are preserved.
    private let micChunker = AudioChunker(speechThreshold: 0.003, strongSpeechThreshold: 0.008, boundaryThreshold: 0.004)

    private var cachedAudioConverter: AVAudioConverter?
    private var cachedMicConverter: AVAudioConverter?

    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private let micQueue = DispatchQueue(label: "com.notability.mic", qos: .userInitiated)

    override init() {
        super.init()
        let publish: (URL, TimeInterval) -> Void = { [weak self] url, ts in
            self?.subject.send((url: url, timestamp: ts))
        }
        systemAudioChunker.onChunk = publish
        micChunker.onChunk = publish
    }

    func startCapture() async throws {
        if let existing = stream {
            try? await existing.stopCapture()
            stream = nil
        }
        isCapturing = false
        captureSession?.stopRunning()
        captureSession = nil
        cachedAudioConverter = nil
        cachedMicConverter = nil
        // Complete the old subject so existing subscribers terminate cleanly.
        subject.send(completion: .finished)
        subject = PassthroughSubject()
        isCapturingSystemAudio = false
        isCapturingMicrophone = false

        // Microphone via AVCaptureSession — only needs Microphone permission.
        // This permission persists across app updates unlike Screen Recording.
        guard await requestMicrophoneAccessIfNeeded() else {
            throw CaptureError.microphonePermissionDenied
        }
        startDate = Date()
        isCapturing = true
        startMicrophoneCapture()
        guard isCapturingMicrophone else {
            isCapturing = false
            startDate = nil
            throw CaptureError.microphoneUnavailable
        }

        // System audio via ScreenCaptureKit — needs Screen Recording permission.
        // Non-fatal if denied: recording continues with microphone only.
        await startSystemAudioCapture()

        guard isCapturingSystemAudio || captureSession?.isRunning == true else {
            throw CaptureError.noAudioSource
        }
    }

    private func startMicrophoneCapture() {
        guard let mic = AVCaptureDevice.default(for: .audio) else { return }

        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: mic) else { return }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: micQueue)

        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        if session.isRunning {
            captureSession = session
            isCapturingMicrophone = true
        } else {
            captureSession = nil
            isCapturingMicrophone = false
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startSystemAudioCapture() async {
        guard let display = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
            .displays.first else {
            print("[AudioCaptureService] Screen Recording unavailable — mic only")
            return
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await s.startCapture()
            stream = s
            isCapturingSystemAudio = true
        } catch {
            print("[AudioCaptureService] System audio capture failed: \(error)")
        }
    }

    func stopCapture() async {
        isCapturing = false
        do { try await stream?.stopCapture() } catch {
            print("[AudioCaptureService] Stream stop error: \(error)")
        }
        stream = nil
        captureSession?.stopRunning()
        captureSession = nil
        isCapturingSystemAudio = false
        isCapturingMicrophone = false
        systemAudioChunker.flush()
        micChunker.flush()
        subject.send(completion: .finished)
    }

    // MARK: - SCStreamOutput (system audio)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processBuffer(sampleBuffer, isMicrophone: false)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleSystemAudioCaptureStopped()
    }

    func handleSystemAudioCaptureStopped() {
        stream = nil
        systemAudioChunker.flush()
        isCapturingSystemAudio = false

        guard isCapturing, !isCapturingMicrophone else { return }
        isCapturing = false
        micChunker.flush()
        subject.send(completion: .finished)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (microphone)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processBuffer(sampleBuffer, isMicrophone: true)
    }

    // MARK: - Shared processing

    private func processBuffer(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        guard isCapturing else { return }  // drop late-arriving callbacks after stopCapture()
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList)

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
        // AVAudioConverter may call the input block multiple times until its
        // output buffer is full. Returning the same srcBuffer with .haveData on
        // every call (the previous behavior) caused the converter to re-process
        // the same frames and leave dstBuffer in an undefined state. Corrupt
        // dstBuffers reaching the chunker were the proximate cause of NULL
        // dereferences observed in production crash logs (com.notability.audiochunker).
        var didProvideInput = false
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        guard error == nil,
              dstBuffer.frameLength > 0,
              dstBuffer.int16ChannelData != nil else { return }

        let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
        if isMicrophone {
            micChunker.append(dstBuffer, timestamp: elapsed)
        } else {
            systemAudioChunker.append(dstBuffer, timestamp: elapsed)
        }
        // Drive waveform from whichever source is louder at any moment
        levelSubject.send(computeRMS(dstBuffer))
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

    enum CaptureError: Error, LocalizedError {
        case noAudioSource
        case microphonePermissionDenied
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .noAudioSource:
                return "No audio source is available. Grant Microphone access or Screen Recording access, then try again."
            case .microphonePermissionDenied:
                return "Microphone access is required so your voice is included in the transcript. Go to System Settings → Privacy & Security → Microphone and enable Notability."
            case .microphoneUnavailable:
                return "Could not start microphone capture. Check your input device and Microphone privacy settings, then try again."
            }
        }
    }
}
