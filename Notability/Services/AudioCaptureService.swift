import ScreenCaptureKit
import AVFoundation
import Combine
import os

final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol,
                                 SCStreamOutput, SCStreamDelegate {

    /// 16 kHz mono Int16 is what recording, live captions and mixing all assume.
    private static let pipelineFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    var captureFormat: AVAudioFormat { Self.pipelineFormat }

    private let relay = CaptureBufferRelay(
        sampleRate: AudioCaptureService.pipelineFormat.sampleRate
    )
    var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> { relay.bufferPublisher }
    var audioLevelPublisher: AnyPublisher<Float, Never> { relay.levelPublisher }

    private let systemAudioAvailabilitySubject = CurrentValueSubject<Bool, Never>(false)
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> {
        systemAudioAvailabilitySubject.eraseToAnyPublisher()
    }

    private let microphoneAvailabilitySubject = CurrentValueSubject<Bool, Never>(false)
    var microphoneAvailabilityPublisher: AnyPublisher<Bool, Never> {
        microphoneAvailabilitySubject.eraseToAnyPublisher()
    }

    private struct Flags {
        var isCapturingMicrophone = false
        var isCapturingSystemAudio = false
        var isEchoCancellationEnabled = false
        var isMicrophoneTapInstalled = false
    }

    /// Written from `startCapture`/`stopCapture`, from the engine configuration
    /// handler on the main queue, and from ScreenCaptureKit's delegate queue when
    /// a stream dies on its own; read by the recording layer. A lock rather than
    /// actor isolation because those delegate callbacks are synchronous.
    private let flags = OSAllocatedUnfairLock(initialState: Flags())

    var isCapturingMicrophone: Bool { flags.withLock { $0.isCapturingMicrophone } }
    var isCapturingSystemAudio: Bool { flags.withLock { $0.isCapturingSystemAudio } }
    var isEchoCancellationEnabled: Bool { flags.withLock { $0.isEchoCancellationEnabled } }

    private let engine = AVAudioEngine()
    /// Locked because ScreenCaptureKit can report the stream dead on its delegate
    /// queue while `stopCapture` is tearing the same stream down.
    private let activeStream = OSAllocatedUnfairLock<SCStream?>(uncheckedState: nil)
    private let microphoneConverter = ResamplingConverter(
        targetFormat: AudioCaptureService.pipelineFormat
    )
    private let systemAudioConverter = ResamplingConverter(
        targetFormat: AudioCaptureService.pipelineFormat
    )
    private var configurationObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func startCapture() async throws {
        await stopCapture()

        microphoneConverter.reset()
        systemAudioConverter.reset()

        guard await requestMicrophoneAccessIfNeeded() else {
            throw CaptureError.microphonePermissionDenied
        }

        relay.open()
        do {
            try startMicrophoneCapture()
        } catch {
            print("[AudioCaptureService] Microphone capture failed: \(error)")
            // Unwinds a partial start: the tap may be installed and voice
            // processing may already be on.
            await stopCapture()
            throw CaptureError.microphoneUnavailable
        }

        // System audio is optional: the meeting is still worth recording with
        // just the microphone when Screen Recording permission is missing.
        await startSystemAudioCapture()
    }

    func stopCapture() async {
        relay.close()

        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        removeMicrophoneTap()
        if engine.isRunning {
            engine.stop()
        }
        flags.withLock { $0.isEchoCancellationEnabled = false }
        setCapturingMicrophone(false)

        let stream = activeStream.withLockUnchecked { stream -> SCStream? in
            defer { stream = nil }
            return stream
        }
        do {
            try await stream?.stopCapture()
        } catch {
            print("[AudioCaptureService] Stream stop error: \(error)")
        }
        setCapturingSystemAudio(false)
    }

    // MARK: - Microphone

    private func startMicrophoneCapture() throws {
        let input = engine.inputNode

        // Voice processing runs the system echo canceller against the default
        // output, removing meeting audio that leaks back in through the
        // speakers. Without it the far end is transcribed twice — once from the
        // system tap, once from the microphone — and billed twice.
        //
        // It depends on the input device and the audio configuration, so it can
        // fail on machines where recording would otherwise work fine. Losing it
        // makes the transcript messier and slightly more expensive; failing
        // startCapture() would leave the user unable to record the meeting at
        // all. The outcome is reported through isEchoCancellationEnabled.
        do {
            try input.setVoiceProcessingEnabled(true)
            flags.withLock { $0.isEchoCancellationEnabled = true }
        } catch {
            flags.withLock { $0.isEchoCancellationEnabled = false }
            print("[AudioCaptureService] Echo cancellation unavailable: \(error)")
        }

        installMicrophoneTap(on: input)
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw CaptureError.microphoneUnavailable }
        setCapturingMicrophone(true)

        // Fires when the user switches input device mid-meeting, e.g. to AirPods.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard relay.isOpen else { return }

        removeMicrophoneTap()
        // The new device brings a new format, and the old resampler state does
        // not belong to it. A tap callback racing this either converts with the
        // outgoing converter or rebuilds; both are safe, because the converter
        // locks its own state and rebuilds whenever the input format changes.
        microphoneConverter.reset()

        let input = engine.inputNode
        installMicrophoneTap(on: input)
        if !engine.isRunning {
            // A restart that fails here costs the rest of the local user's voice
            // while system audio keeps recording, so it has to be visible rather
            // than folded into a boolean nobody is watching.
            do {
                try engine.start()
            } catch {
                print("[AudioCaptureService] Engine restart after device change failed: \(error)")
            }
        }
        setCapturingMicrophone(engine.isRunning)
    }

    private func installMicrophoneTap(on input: AVAudioInputNode) {
        // Read fresh on every install: enabling voice processing changes the
        // node's output format, and so does switching input device.
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.publish(buffer, from: .microphone, through: self.microphoneConverter)
        }
        flags.withLock { $0.isMicrophoneTapInstalled = true }
    }

    private func removeMicrophoneTap() {
        let wasInstalled = flags.withLock { flags -> Bool in
            guard flags.isMicrophoneTapInstalled else { return false }
            flags.isMicrophoneTapInstalled = false
            return true
        }
        guard wasInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - System audio

    private func startSystemAudioCapture() async {
        guard let display = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
            .displays.first else {
            print("[AudioCaptureService] Screen Recording unavailable — mic only")
            return
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(captureFormat.sampleRate)
        configuration.channelCount = 1
        // Without this the app's own notification sounds land in the transcript.
        configuration.excludesCurrentProcessAudio = true
        // Video cannot be switched off, so ask for the smallest, slowest frames
        // ScreenCaptureKit will accept.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: .global(qos: .userInitiated)
            )
            try await newStream.startCapture()
            activeStream.withLockUnchecked { $0 = newStream }
            setCapturingSystemAudio(true)
        } catch {
            print("[AudioCaptureService] System audio capture failed: \(error)")
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, let description = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )

        publish(buffer, from: .systemAudio, through: systemAudioConverter)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioCaptureService] System audio stream stopped: \(error)")
        handleSystemAudioCaptureStopped()
    }

    /// The system audio stream ended on its own — a display disconnect, or the
    /// user revoking Screen Recording mid-meeting. The microphone keeps going and
    /// the buffer publisher stays open, so the recording survives losing this
    /// half of the audio.
    func handleSystemAudioCaptureStopped() {
        activeStream.withLockUnchecked { $0 = nil }
        setCapturingSystemAudio(false)
    }

    private func setCapturingMicrophone(_ value: Bool) {
        let changed = flags.withLock { flags -> Bool in
            guard flags.isCapturingMicrophone != value else { return false }
            flags.isCapturingMicrophone = value
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [microphoneAvailabilitySubject] in
            microphoneAvailabilitySubject.send(value)
        }
    }

    private func setCapturingSystemAudio(_ value: Bool) {
        let changed = flags.withLock { flags -> Bool in
            guard flags.isCapturingSystemAudio != value else { return false }
            flags.isCapturingSystemAudio = value
            return true
        }
        guard changed else { return }
        // Hopped to the main queue so the three contexts that can change this
        // cannot send concurrently, and because the only subscriber is UI. The
        // getter is already up to date, so a caller reading the flag straight
        // after startCapture() returns does not depend on this.
        DispatchQueue.main.async { [systemAudioAvailabilitySubject] in
            systemAudioAvailabilitySubject.send(value)
        }
    }

    // MARK: - Shared processing

    private func publish(
        _ buffer: AVAudioPCMBuffer,
        from source: AudioSource,
        through converter: ResamplingConverter
    ) {
        guard var converted = converter.convert(buffer) else { return }

        if converted === buffer {
            // The engine reuses its tap buffer as soon as the callback returns,
            // and subscribers keep what they are handed. Conversion allocates a
            // fresh buffer, but a format-matched passthrough hands back the
            // input, so that case has to be copied.
            guard let owned = Self.copy(converted) else { return }
            converted = owned
        }

        relay.send(converted, from: source)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }

    enum CaptureError: Error, LocalizedError {
        case microphonePermissionDenied
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access is required so your voice is included in the transcript. Go to System Settings → Privacy & Security → Microphone and enable Notability."
            case .microphoneUnavailable:
                return "Could not start microphone capture. Check your input device and Microphone privacy settings, then try again."
            }
        }
    }
}
