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

    /// The other tests only check the extracted clip's duration, which a wrong
    /// start-offset calculation could still satisfy. The system track here is
    /// quiet for exactly one window's worth of audio — [8s, 18s) out of a 20s
    /// recording — so exactly one of the 10s windows can qualify and the
    /// extractor has no slack to land on a neighbouring offset. Measuring the
    /// clip's RMS then proves it came from that window: the mic is silent
    /// outside it, so any other offset mixes in silence and reads lower.
    func test_extracted_window_starts_where_the_system_track_actually_goes_quiet() throws {
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let totalSeconds = 20.0
        let quietRange = 8.0..<18.0

        let micBuffer = AudioFixtures.buffer(seconds: totalSeconds) { index in
            let seconds = Double(index) / 16_000
            guard quietRange.contains(seconds) else { return 0 }
            return 0.4 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        let systemBuffer = AudioFixtures.buffer(seconds: totalSeconds) { index in
            let seconds = Double(index) / 16_000
            guard !quietRange.contains(seconds) else { return 0 }
            return 0.4 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        try AudioFixtures.writeWAV(micBuffer, to: micURL)
        try AudioFixtures.writeWAV(systemBuffer, to: systemURL)

        let reference = try SpeakerReferenceExtractor.extract(micURL: micURL, systemURL: systemURL)

        let data = try XCTUnwrap(reference)
        let extractedURL = directory.appendingPathComponent("ref.wav")
        try data.write(to: extractedURL)

        let extracted = try samples(ofFileAt: extractedURL)
        let expected = samples(of: micBuffer)
        let start = Int(quietRange.lowerBound * 16_000)
        XCTAssertEqual(extracted.count, 160_000)
        // A 440 Hz tone at 16 kHz has a 36.4-frame period, so comparing
        // samples rather than an aggregate like RMS catches a start offset
        // that is wrong by even a single frame.
        XCTAssertEqual(Array(extracted.prefix(256)), Array(expected[start..<(start + 256)]))
        XCTAssertEqual(Array(extracted.suffix(256)), Array(expected[(start + 160_000 - 256)..<(start + 160_000)]))
    }

    private func samples(of buffer: AVAudioPCMBuffer) -> [Int16] {
        let channel = buffer.int16ChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func samples(ofFileAt url: URL) throws -> [Int16] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!

        // AVAudioFile.read stops on an internal buffer boundary well short of
        // a ten-second request, so a single call would silently truncate.
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            result.append(contentsOf: samples(of: buffer))
        }
        return result
    }
}
