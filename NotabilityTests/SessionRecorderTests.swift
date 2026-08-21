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
        recorder.append(AudioFixtures.tone(seconds: 0.5))
        recorder.finish()

        XCTAssertEqual(recorder.url.lastPathComponent, "mic.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    func test_recorded_duration_matches_appended_audio() throws {
        let recorder = try SessionRecorder(directory: directory, source: .systemAudio, sampleRate: 16_000)
        for _ in 0..<4 {
            recorder.append(AudioFixtures.tone(seconds: 0.5))
        }
        recorder.finish()

        let file = try AVAudioFile(forReading: recorder.url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 2.0, accuracy: 0.1)
    }

    func test_successful_recording_reports_no_write_error() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 1.0))
        recorder.finish()

        XCTAssertNil(recorder.writeError)
    }

    func test_append_after_finish_is_ignored() throws {
        let recorder = try SessionRecorder(directory: directory, source: .microphone, sampleRate: 16_000)
        recorder.append(AudioFixtures.tone(seconds: 1.0))
        recorder.finish()
        recorder.append(AudioFixtures.tone(seconds: 1.0))

        let file = try AVAudioFile(forReading: recorder.url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 1.0, accuracy: 0.1)
    }
}
