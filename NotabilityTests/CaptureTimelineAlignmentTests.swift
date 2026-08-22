import XCTest
import AVFoundation
import Combine
@testable import Notability

/// Drives the whole recorded-audio path — relay, router, both `SessionRecorder`s
/// — with system audio attaching seconds after the microphone, and then checks
/// the two things that read the resulting files: the mix that gets transcribed,
/// and the speaker reference that decides who is who in it.
///
/// This is the integration these components were missing. Each of them is
/// individually correct against its own idea of "frame *n*"; what went wrong was
/// that the two sources disagreed about which instant frame *n* was, and only a
/// test that starts them apart and reads the files back can see that.
///
/// Timeline the test builds, measured from the shared origin:
///
/// ```
///          0s        3s        5s        6s        8s
/// mic      |·········|~~~~~~~~~|·········|·········|
/// system   (not attached)      |·········|~~~~~~~~~|
/// ```
///
/// with `~` a tone and `·` silence. It is arranged so that misalignment is not
/// merely visible but inverts both answers: slide the system track three
/// seconds early and its tone lands underneath the microphone's, so the mix has
/// both voices at 3–5 s and nothing at 6–8 s, and the extractor can no longer
/// find any stretch where the microphone speaks and the far end does not.
final class CaptureTimelineAlignmentTests: XCTestCase {
    private let sampleRate: Double = 16_000
    private let bufferSeconds = 0.1
    private let systemAudioAttachesAt = 3.0
    private let recordingSeconds = 8.0

    private var directory: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_both_tracks_span_the_same_interval_despite_starting_apart() throws {
        let tracks = try record()

        XCTAssertEqual(try duration(of: tracks.mic), recordingSeconds, accuracy: 0.1)
        XCTAssertEqual(
            try duration(of: tracks.system),
            recordingSeconds,
            accuracy: 0.1,
            "system audio attached \(systemAudioAttachesAt) s late; its track has to be padded "
                + "by that much or every sample index after it means a different instant"
        )
    }

    func test_the_mixed_file_keeps_each_voice_where_it_was_spoken() throws {
        let tracks = try record()
        let mixed = directory.appendingPathComponent("mixed.m4a")

        try AudioMixer.mix(tracks: [tracks.mic, tracks.system], to: mixed)

        XCTAssertEqual(try rms(of: mixed, from: 0.2, to: 2.8), 0, accuracy: 0.02, "0–3 s: nobody spoke")
        XCTAssertGreaterThan(try rms(of: mixed, from: 3.2, to: 4.8), 0.1, "3–5 s: the local user spoke")
        XCTAssertEqual(try rms(of: mixed, from: 5.2, to: 5.8), 0, accuracy: 0.02, "5–6 s: nobody spoke")
        XCTAssertGreaterThan(
            try rms(of: mixed, from: 6.2, to: 7.8),
            0.1,
            "6–8 s: the far end spoke, and a system track stamped from its own frame zero "
                + "would have put this three seconds earlier, on top of the local user"
        )
    }

    func test_the_speaker_reference_comes_from_audio_the_far_end_was_absent_from() throws {
        let tracks = try record()
        var config = SpeakerReferenceExtractor.Config()
        config.windowDuration = 1

        let reference = try SpeakerReferenceExtractor.extract(
            micURL: tracks.mic,
            systemURL: tracks.system,
            config: config
        )

        let samples = try XCTUnwrap(
            reference,
            "3–5 s is the only stretch where the local user speaks, and the far end is silent "
                + "there — unless the system track is read three seconds out of step, which puts "
                + "its tone under that stretch and leaves no qualifying window at all"
        )
        XCTAssertGreaterThan(
            try rms(ofWAV: samples),
            0.1,
            "the reference was cut from silence, so it names nobody"
        )
    }

    // MARK: - Recording the fixture

    private struct Tracks {
        let mic: URL
        let system: URL
    }

    /// Replays the timeline above through the real capture plumbing: buffers are
    /// stamped by `CaptureBufferRelay` against its shared origin and fanned out
    /// by `CaptureBufferRouter`, exactly as a live recording does. Only the
    /// clock and the audio itself are substituted.
    private func record() throws -> Tracks {
        let clock = TestMonotonicClock()
        let relay = CaptureBufferRelay(sampleRate: sampleRate, clock: clock.read)
        let micRecorder = try SessionRecorder(
            directory: directory, source: .microphone, sampleRate: sampleRate
        )
        let systemRecorder = try SessionRecorder(
            directory: directory, source: .systemAudio, sampleRate: sampleRate
        )
        let router = CaptureBufferRouter(
            recorders: [.microphone: micRecorder, .systemAudio: systemRecorder],
            liveTranscription: FakeLiveTranscriptionService()
        )
        relay.bufferPublisher.sink { router.route($0) }.store(in: &cancellables)

        relay.open()
        for step in 0..<Int(recordingSeconds / bufferSeconds) {
            let instant = Double(step) * bufferSeconds
            // A callback fires once its buffer is full, so the clock reads one
            // buffer past the audio's own start time.
            clock.set(to: instant + bufferSeconds)
            relay.send(micAudio(at: instant), from: .microphone)
            guard instant >= systemAudioAttachesAt else { continue }
            relay.send(systemAudio(at: instant), from: .systemAudio)
        }
        relay.close()

        micRecorder.finish()
        systemRecorder.finish()
        XCTAssertNil(micRecorder.writeError)
        XCTAssertNil(systemRecorder.writeError)
        return Tracks(mic: micRecorder.url, system: systemRecorder.url)
    }

    /// The local user speaks from 3 s to 5 s.
    private func micAudio(at instant: TimeInterval) -> AVAudioPCMBuffer {
        (3.0..<5.0).contains(instant)
            ? AudioFixtures.tone(seconds: bufferSeconds, amplitude: 0.8)
            : AudioFixtures.silence(seconds: bufferSeconds)
    }

    /// The far end speaks from 6 s to 8 s.
    private func systemAudio(at instant: TimeInterval) -> AVAudioPCMBuffer {
        instant >= 6.0
            ? AudioFixtures.tone(seconds: bufferSeconds, amplitude: 0.8)
            : AudioFixtures.silence(seconds: bufferSeconds)
    }

    // MARK: - Reading the result

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func rms(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let wanted = AVAudioFrameCount((end - start) * rate)
        guard AVAudioFramePosition(end * rate) <= file.length else {
            XCTFail("\(url.lastPathComponent) is only \(Double(file.length) / rate) s long")
            return .nan
        }

        file.framePosition = AVAudioFramePosition(start * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted)!
        var samples: [Int16] = []
        while samples.count < Int(wanted), file.framePosition < file.length {
            try file.read(into: buffer, frameCount: wanted - AVAudioFrameCount(samples.count))
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)
            ))
        }
        return Self.rms(of: samples)
    }

    /// RMS of a 16-bit PCM WAV, skipping its 44-byte canonical header.
    private func rms(ofWAV data: Data) throws -> Float {
        let payload = data.dropFirst(44)
        let samples = payload.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        return Self.rms(of: samples)
    }

    private static func rms(of samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample) / 32_768
            sum += value * value
        }
        return sqrt(sum / Float(samples.count))
    }
}
