import XCTest
import AVFoundation
@testable import Notability

final class SpeakerReferenceExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_extracts_window_when_mic_speaks_alone() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 15, amplitude: 0.4), to: micURL)
        try AudioFixtures.writeWAV(AudioFixtures.silence(seconds: 15), to: systemURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: systemURL)

        let data = try XCTUnwrap(reference)
        let extractedURL = directory.appendingPathComponent("ref.wav")
        try data.write(to: extractedURL)
        let file = try AVAudioFile(forReading: extractedURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 10.0, accuracy: 0.05)
    }

    func test_returns_nil_when_mic_is_silent() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        try AudioFixtures.writeWAV(AudioFixtures.silence(seconds: 20), to: micURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: nil)

        XCTAssertNil(reference)
    }

    func test_returns_nil_when_system_audio_overlaps_all_mic_speech() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 15, amplitude: 0.4), to: micURL)
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 15, amplitude: 0.4), to: systemURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: systemURL)

        XCTAssertNil(reference)
    }

    func test_returns_nil_when_mic_track_is_shorter_than_window() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 4, amplitude: 0.4), to: micURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: nil)

        XCTAssertNil(reference)
    }

    /// The other tests only check the extracted clip's duration, which a
    /// wrong start-offset calculation could still satisfy. Here the mic is
    /// silent until the system track goes quiet at 8s, so only a window
    /// starting at 8s is valid; checking the extracted clip's RMS confirms
    /// it actually came from the tone at [8s, 18s) and not from the silent
    /// lead-in or some other offset.
    func test_extracted_window_starts_where_the_system_track_actually_goes_quiet() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let totalSeconds = 20.0
        let quietAt = 8.0

        let micBuffer = AudioFixtures.buffer(seconds: totalSeconds) { index in
            let seconds = Double(index) / 16_000
            guard seconds >= quietAt else { return 0 }
            return 0.4 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        let systemBuffer = AudioFixtures.buffer(seconds: totalSeconds) { index in
            let seconds = Double(index) / 16_000
            guard seconds < quietAt else { return 0 }
            return 0.4 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        try AudioFixtures.writeWAV(micBuffer, to: micURL)
        try AudioFixtures.writeWAV(systemBuffer, to: systemURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: systemURL)

        let data = try XCTUnwrap(reference)
        let extractedURL = directory.appendingPathComponent("ref.wav")
        try data.write(to: extractedURL)
        // A window drawn from the silent lead-in (or any offset that mixes
        // silence and tone) would measure far below this; only [8s, 18s) is
        // pure 0.4-amplitude tone, whose RMS is amplitude / sqrt(2) ≈ 0.283.
        let rms = try AudioFixtures.rms(ofFileAt: extractedURL)
        XCTAssertEqual(rms, 0.283, accuracy: 0.05)
    }
}
