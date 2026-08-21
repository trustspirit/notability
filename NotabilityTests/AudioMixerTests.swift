import XCTest
import AVFoundation
@testable import Notability

final class AudioMixerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_output_length_matches_longest_track() throws {
        let shortURL = directory.appendingPathComponent("short.wav")
        let longURL = directory.appendingPathComponent("long.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 1.0), to: shortURL)
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 3.0), to: longURL)

        let output = directory.appendingPathComponent("mixed.m4a")
        try AudioMixer.mix(tracks: [shortURL, longURL], to: output)

        let file = try AVAudioFile(forReading: output)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 3.0, accuracy: 0.15)
    }

    func test_mixing_tone_with_silence_halves_amplitude() throws {
        let toneURL = directory.appendingPathComponent("tone.wav")
        let silenceURL = directory.appendingPathComponent("silence.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 2.0, amplitude: 0.8), to: toneURL)
        try AudioFixtures.writeWAV(AudioFixtures.silence(seconds: 2.0), to: silenceURL)

        let output = directory.appendingPathComponent("mixed.m4a")
        try AudioMixer.mix(tracks: [toneURL, silenceURL], to: output)

        // 0.8 amplitude sine has RMS ≈ 0.566; halved by the 0.5 mix gain ≈ 0.283.
        let rms = try AudioFixtures.rms(ofFileAt: output)
        XCTAssertEqual(rms, 0.283, accuracy: 0.05)
    }

    func test_single_track_is_still_attenuated_by_gain() throws {
        let toneURL = directory.appendingPathComponent("tone.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 1.0, amplitude: 0.8), to: toneURL)

        let output = directory.appendingPathComponent("mixed.m4a")
        try AudioMixer.mix(tracks: [toneURL], to: output)

        let rms = try AudioFixtures.rms(ofFileAt: output)
        XCTAssertEqual(rms, 0.283, accuracy: 0.05)
    }

    func test_empty_track_list_throws() {
        let output = directory.appendingPathComponent("mixed.m4a")
        XCTAssertThrowsError(try AudioMixer.mix(tracks: [], to: output))
    }

    func test_track_length_exact_multiple_of_chunk_size_is_handled() throws {
        // 16,384 frames is one chunk at 16 kHz (1.024 s); 32,768 frames (2.048 s)
        // makes the short track exhaust on a chunk boundary, where a fresh read
        // returns zero frames rather than a partial one.
        let shortURL = directory.appendingPathComponent("short.wav")
        let longURL = directory.appendingPathComponent("long.wav")
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 2.048), to: shortURL)
        try AudioFixtures.writeWAV(AudioFixtures.tone(seconds: 3.0), to: longURL)

        let output = directory.appendingPathComponent("mixed.m4a")
        try AudioMixer.mix(tracks: [shortURL, longURL], to: output)

        let file = try AVAudioFile(forReading: output)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 3.0, accuracy: 0.15)
    }
}
