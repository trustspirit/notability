import XCTest
import AVFoundation
@testable import Notability

final class FrameClockTests: XCTestCase {
    func test_first_advance_returns_zero() {
        var clock = FrameClock(sampleRate: 16_000)
        XCTAssertEqual(clock.advance(by: 1_600), 0, accuracy: 1e-9)
    }

    func test_advance_returns_start_time_of_each_buffer() {
        var clock = FrameClock(sampleRate: 16_000)
        XCTAssertEqual(clock.advance(by: 1_600), 0.0, accuracy: 1e-9)
        XCTAssertEqual(clock.advance(by: 1_600), 0.1, accuracy: 1e-9)
        XCTAssertEqual(clock.advance(by: 8_000), 0.2, accuracy: 1e-9)
        XCTAssertEqual(clock.advance(by: 1_600), 0.7, accuracy: 1e-9)
    }

    func test_elapsed_reflects_total_frames() {
        var clock = FrameClock(sampleRate: 16_000)
        _ = clock.advance(by: 16_000)
        _ = clock.advance(by: 8_000)
        XCTAssertEqual(clock.elapsed, 1.5, accuracy: 1e-9)
    }

    func test_timestamps_are_strictly_monotonic_across_many_buffers() {
        var clock = FrameClock(sampleRate: 16_000)
        var previous = -1.0
        for _ in 0..<10_000 {
            let t = clock.advance(by: 512)
            XCTAssertGreaterThan(t, previous)
            previous = t
        }
    }

    func test_audioSource_speaker_labels() {
        XCTAssertEqual(AudioSource.microphone.defaultSpeakerLabel, "나")
        XCTAssertEqual(AudioSource.systemAudio.defaultSpeakerLabel, "상대방")
    }

    func test_audioSource_file_base_names() {
        XCTAssertEqual(AudioSource.microphone.fileBaseName, "mic")
        XCTAssertEqual(AudioSource.systemAudio.fileBaseName, "system")
    }
}
