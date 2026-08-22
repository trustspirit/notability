import XCTest
import AVFoundation
@testable import Notability

final class SessionRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_writes_file_named_after_source() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 0.5), startTime: 0)
        recorder.finish()

        XCTAssertEqual(recorder.url.lastPathComponent, "mic.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    func test_recorded_duration_matches_appended_audio() throws {
        let recorder = try SessionRecorder(directory: directory, source: .systemAudio, sampleRate: 16_000)
        for index in 0..<4 {
            recorder.append(AudioFixtures.tone(seconds: 0.5), startTime: Double(index) * 0.5)
        }
        recorder.finish()

        XCTAssertEqual(try duration(of: recorder.url), 2.0, accuracy: 0.1)
    }

    func test_successful_recording_reports_no_write_error() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 1.0), startTime: 0)
        recorder.finish()

        XCTAssertNil(recorder.writeError)
    }

    func test_append_after_finish_is_ignored() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 1.0), startTime: 0)
        recorder.finish()
        recorder.append(AudioFixtures.tone(seconds: 1.0), startTime: 1.0)

        XCTAssertEqual(try duration(of: recorder.url), 1.0, accuracy: 0.1)
    }

    // MARK: - Alignment padding

    /// A source that starts late must still occupy the same sample indices as
    /// one that started on time, or the mixer sums two different instants.
    func test_a_late_first_buffer_is_preceded_by_its_offset_in_silence() throws {
        let recorder = try SessionRecorder(directory: directory, source: .systemAudio, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 1.0), startTime: 3.0)
        recorder.finish()

        XCTAssertEqual(try duration(of: recorder.url), 4.0, accuracy: 0.1)
        XCTAssertEqual(try rms(of: recorder.url, from: 0.2, to: 2.8), 0, accuracy: 0.01)
        XCTAssertGreaterThan(try rms(of: recorder.url, from: 3.2, to: 3.8), 0.1)
    }

    /// The gap an engine restart leaves behind. Concatenating instead would put
    /// the tone at 1 s and drag the rest of the track two seconds early.
    func test_a_gap_between_buffers_is_filled_rather_than_closed_up() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.silence(seconds: 1.0), startTime: 0)
        recorder.append(AudioFixtures.tone(seconds: 1.0), startTime: 3.0)
        recorder.finish()

        XCTAssertEqual(try duration(of: recorder.url), 4.0, accuracy: 0.1)
        XCTAssertEqual(try rms(of: recorder.url, from: 1.2, to: 2.8), 0, accuracy: 0.01)
        XCTAssertGreaterThan(try rms(of: recorder.url, from: 3.2, to: 3.8), 0.1)
    }

    /// The ordinary case: timestamps advance by delivered frames, so buffer
    /// after buffer there is nothing to pad and nothing is inserted.
    func test_contiguous_buffers_are_written_back_to_back() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        for index in 0..<10 {
            recorder.append(AudioFixtures.tone(seconds: 0.1), startTime: Double(index) * 0.1)
        }
        recorder.finish()

        XCTAssertEqual(try duration(of: recorder.url), 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(try rms(of: recorder.url, from: 0.2, to: 0.8), 0.1)
    }

    /// Padding is chunked, so a gap longer than one chunk still lands exactly.
    func test_a_gap_longer_than_one_padding_chunk_lands_exactly() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 0.1), startTime: 0)
        recorder.append(AudioFixtures.tone(seconds: 0.1), startTime: 30.0)
        recorder.finish()

        XCTAssertEqual(try duration(of: recorder.url), 30.1, accuracy: 0.1)
    }

    // MARK: - Helpers

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func rms(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(start * rate)
        let count = AVAudioFrameCount((end - start) * rate)
        guard first + AVAudioFramePosition(count) <= file.length else {
            XCTFail("track is only \(Double(file.length) / rate) s, cannot read \(start)–\(end) s")
            return .nan
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        file.framePosition = first
        var sum: Float = 0
        var read = 0
        while read < Int(count), file.framePosition < file.length {
            try file.read(into: buffer, frameCount: count - AVAudioFrameCount(read))
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            for index in 0..<framesRead {
                let value = Float(buffer.int16ChannelData![0][index]) / 32_768
                sum += value * value
            }
            read += framesRead
        }
        return read > 0 ? sqrt(sum / Float(read)) : 0
    }
}
