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
}
