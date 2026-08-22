import ScreenCaptureKit
import AVFoundation
import Combine
import os

/// Isolated to the main actor because `engine` is mutated — taps installed and
/// removed, started and stopped — from `startCapture`, from `stopCapture`, and
/// from the `AVAudioEngineConfigurationChange` handler, and `AVAudioEngine` has
/// no lock of its own. Nothing else serialized those three: a non-isolated
/// class's `async` methods run on the cooperative pool whatever the caller is
/// on, so the handler, which is registered on the main queue, could land in the
/// middle of either. That is what left `stopCapture()` returning with the
/// microphone still open, and what let one bus be tapped twice — an
/// `NSInternalInconsistencyException` no `catch` can reach.
///
/// The audio path stays off the actor entirely. Everything a capture callback
/// touches — `relay`, `flags`, the converters, the tap block, the
/// ScreenCaptureKit delegate methods — is `nonisolated` and carries its own
/// lock, so a buffer still travels from the callback to its subscribers
/// synchronously on the capturing thread with no hop. Per-source ordering
/// depends on that; see `AudioCaptureServiceProtocol.bufferPublisher`.
@MainActor
final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol,
                                 SCStreamOutput, SCStreamDelegate {

    /// 16 kHz mono Int16 is what recording, live captions and mixing all assume.
    private nonisolated static let pipelineFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    nonisolated var captureFormat: AVAudioFormat { Self.pipelineFormat }

    private nonisolated let relay = CaptureBufferRelay(
        sampleRate: AudioCaptureService.pipelineFormat.sampleRate
    )
    nonisolated var bufferPublisher: AnyPublisher<TaggedAudioBuffer, Never> {
        relay.bufferPublisher
    }
    nonisolated var audioLevelPublisher: AnyPublisher<Float, Never> { relay.levelPublisher }

    /// Owns the system audio stream and the flag that says it is running, which
    /// have to move together; see `SystemAudioOwnership`.
    private nonisolated let systemAudio = SystemAudioOwnership<SCStream>()
    nonisolated var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> {
        systemAudio.availabilityPublisher
    }

    private nonisolated let microphoneAvailabilitySubject = CurrentValueSubject<Bool, Never>(false)
    nonisolated var microphoneAvailabilityPublisher: AnyPublisher<Bool, Never> {
        microphoneAvailabilitySubject.eraseToAnyPublisher()
    }

    /// Nonisolated so a caller on any context can own the instance before it
    /// has an actor to hop to; nothing here touches isolated state.
    nonisolated override init() {
        super.init()
    }

    private struct Flags {
        var isCapturingMicrophone = false
        var isEchoCancellationEnabled = false
        var isMicrophoneTapInstalled = false
    }

    /// Written from `startCapture`/`stopCapture` and the device-change handler,
    /// all on the main actor, and read by the recording layer from wherever it
    /// happens to be. A lock rather than actor isolation because the tap block
    /// also sets `isMicrophoneTapInstalled` and cannot wait for a hop.
    private nonisolated let flags = OSAllocatedUnfairLock(initialState: Flags())

    nonisolated var isCapturingMicrophone: Bool { flags.withLock { $0.isCapturingMicrophone } }
    nonisolated var isCapturingSystemAudio: Bool { systemAudio.isRunning }
    nonisolated var isEchoCancellationEnabled: Bool {
        flags.withLock { $0.isEchoCancellationEnabled }
    }

    /// Main-actor isolated, which is the whole point: it has no lock of its own
    /// and three contexts used to reach it.
    private let engine = AVAudioEngine()
    private nonisolated let microphoneConverter = ResamplingConverter(
        targetFormat: AudioCaptureService.pipelineFormat
    )
    private nonisolated let systemAudioConverter = ResamplingConverter(
        targetFormat: AudioCaptureService.pipelineFormat
    )
    private var configurationObserver: NSObjectProtocol?
    /// Distinguishes the current recording's device-change handler from one
    /// belonging to an earlier one. `removeObserver` cannot recall a block that
    /// has already been enqueued on the main queue, so a stale handler can still
    /// run — and by then the next recording may have opened the relay, which
    /// makes `relay.isOpen` alone no longer enough to recognise it.
    private var captureGeneration = 0

    // MARK: - Lifecycle

    func startCapture() async throws {
        await stopCapture()

        captureGeneration += 1
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

        // Disowned before the await, not after it: from here on the stream is
        // nobody's, so a death reported while it is shutting down changes
        // nothing, and a caller looking at the flag during the shutdown is not
        // told system audio is still running.
        let stream = systemAudio.take()
        do {
            try await stream?.stopCapture()
        } catch {
            print("[AudioCaptureService] Stream stop error: \(error)")
        }
    }

    // MARK: - Microphone

    private func startMicrophoneCapture() throws {
        let input = engine.inputNode

        // Voice processing runs the system echo canceller against the default
        // output, removing meeting audio that leaks back in through the
        // speakers. Without it the far end reaches the microphone as well as the
        // system tap, so the mix carries it twice and it can be transcribed twice
        // and attributed to the local speaker.
        //
        // It depends on the input device and the audio configuration, so it can
        // fail on machines where recording would otherwise work fine. Losing it
        // makes the transcript messier; failing startCapture() would leave the
        // user unable to record the meeting at all. The outcome is reported
        // through isEchoCancellationEnabled.
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
        //
        // `queue: .main` means the block already runs on the main thread, so
        // `assumeIsolated` claims the actor without a hop. Hopping instead would
        // let a stop, or a whole next recording, slip in between the switch and
        // the response to it.
        let generation = captureGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange(generation: generation)
            }
        }
    }

    private func handleConfigurationChange(generation: Int) {
        guard generation == captureGeneration, relay.isOpen else { return }

        removeMicrophoneTap()
        // The new device brings a new format, and the old resampler state does
        // not belong to it. A tap callback racing this either converts with the
        // outgoing converter or rebuilds; both are safe, because the converter
        // locks its own state and rebuilds whenever the input format changes.
        microphoneConverter.reset()
        // Restarting the engine costs however long the switch takes, and those
        // frames are never delivered. Counting frames alone would splice the
        // gap shut and slide the rest of the microphone track ahead of system
        // audio, which kept recording throughout.
        relay.resynchronize(.microphone)

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
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: makeTapBlock())
        flags.withLock { $0.isMicrophoneTapInstalled = true }
    }

    /// Built in a nonisolated context so the block does not inherit this type's
    /// main-actor isolation. The audio engine calls it on its own realtime
    /// thread, and everything it reaches carries its own lock.
    private nonisolated func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            guard let self else { return }
            self.publish(buffer, from: .microphone, through: self.microphoneConverter)
        }
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
        // Claimed from the moment it exists, because `self` is already its
        // delegate: `stream(_:didStopWithError:)` can fire on ScreenCaptureKit's
        // queue before `startCapture()` has finished returning, and only a
        // stream that is already owned can be recognised as the one that died.
        systemAudio.claim(newStream)
        do {
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: .global(qos: .userInitiated)
            )
            try await newStream.startCapture()
            systemAudio.markRunning(newStream)
        } catch {
            print("[AudioCaptureService] System audio capture failed: \(error)")
            systemAudio.release(newStream)
        }
    }

    nonisolated func stream(
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

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioCaptureService] System audio stream stopped: \(error)")
        handleSystemAudioCaptureStopped(stream)
    }

    /// The system audio stream ended on its own — a display disconnect, or the
    /// user revoking Screen Recording mid-meeting. The microphone keeps going and
    /// the buffer publisher stays open, so the recording survives losing this
    /// half of the audio.
    ///
    /// Pass the stream that died. One this service no longer owns is ignored, so
    /// a previous recording's stream reporting late cannot take down the current
    /// one. Passing nil means whichever stream is held, for a caller with no
    /// particular one in hand.
    nonisolated func handleSystemAudioCaptureStopped(_ stream: SCStream? = nil) {
        guard let stream else { return systemAudio.releaseAny() }
        systemAudio.release(stream)
    }

    private nonisolated func setCapturingMicrophone(_ value: Bool) {
        flags.withLock { flags in
            guard flags.isCapturingMicrophone != value else { return }
            flags.isCapturingMicrophone = value
            // Enqueued under the lock so subscribers see these in the order they
            // happened, and capturing `self` rather than the subject because a
            // `@MainActor` class is Sendable and a Combine subject is not.
            DispatchQueue.main.async { [self] in
                microphoneAvailabilitySubject.send(value)
            }
        }
    }

    // MARK: - Shared processing

    private nonisolated func publish(
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

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
