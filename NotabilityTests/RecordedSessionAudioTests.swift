import XCTest
import AVFoundation
@testable import Notability

/// The distinction these cover is what makes the difference between offering a
/// user a Retry that works and one that fails identically every time: a track
/// file exists on disk from the moment recording starts, but only becomes
/// decodable when its container is completed.
final class RecordedSessionAudioTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func test_finished_tracks_are_usable_and_both_are_offered_for_mixing() throws {
        try write(.microphone, AudioFixtures.tone(seconds: 0.5))
        try write(.systemAudio, AudioFixtures.tone(seconds: 0.5))

        XCTAssertEqual(
            RecordedSessionAudio.inspect(directory: directory),
            .usable(tracks: [url(.microphone), url(.systemAudio)])
        )
    }

    func test_a_microphone_only_recording_is_usable() throws {
        try write(.microphone, AudioFixtures.tone(seconds: 0.5))
        // What a meeting recorded without Screen Recording permission leaves:
        // the file is created when recording starts and never written to.
        try AudioFixtures.writeEmptyTrack(to: url(.systemAudio))

        XCTAssertEqual(
            RecordedSessionAudio.inspect(directory: directory),
            .usable(tracks: [url(.microphone)]),
            "An empty second track must not be handed to the mixer"
        )
    }

    /// The defect itself: a crash or a force quit leaves every track with its
    /// samples written and its container unfinished.
    func test_unfinalized_tracks_are_reported_unreadable() throws {
        try AudioFixtures.writeUnfinalizedTrack(AudioFixtures.tone(seconds: 0.5), to: url(.microphone))
        try AudioFixtures.writeUnfinalizedTrack(AudioFixtures.tone(seconds: 0.5), to: url(.systemAudio))

        XCTAssertNil(
            try? AVAudioFile(forReading: url(.microphone)),
            "The fixture has to be genuinely undecodable or this proves nothing"
        )
        XCTAssertEqual(RecordedSessionAudio.inspect(directory: directory), .unreadable)
        XCTAssertFalse(RecordedSessionAudio.isUsable(directory: directory))
    }

    /// Dying between the two `finish()` calls is a microsecond-wide window, but
    /// what survives it is still worth transcribing.
    func test_one_finished_track_beside_an_unfinalized_one_is_still_usable() throws {
        try write(.microphone, AudioFixtures.tone(seconds: 0.5))
        try AudioFixtures.writeUnfinalizedTrack(AudioFixtures.tone(seconds: 0.5), to: url(.systemAudio))

        XCTAssertEqual(
            RecordedSessionAudio.inspect(directory: directory),
            .usable(tracks: [url(.microphone)])
        )
    }

    func test_tracks_that_were_closed_without_any_audio_are_empty_not_unreadable() throws {
        try AudioFixtures.writeEmptyTrack(to: url(.microphone))
        try AudioFixtures.writeEmptyTrack(to: url(.systemAudio))

        XCTAssertEqual(
            RecordedSessionAudio.inspect(directory: directory),
            .empty,
            "These files are fine — there is just nothing in them, which is a different thing to say"
        )
    }

    func test_a_directory_with_no_tracks_is_empty() {
        XCTAssertEqual(RecordedSessionAudio.inspect(directory: directory), .empty)
    }

    func test_a_missing_directory_is_empty() {
        let missing = directory.appendingPathComponent("gone")
        XCTAssertEqual(RecordedSessionAudio.inspect(directory: missing), .empty)
    }

    /// `mixed.m4a` is written into the same directory by a previous attempt.
    /// Feeding it back in would mix the recording with itself.
    func test_only_the_per_source_tracks_are_reported() throws {
        try write(.microphone, AudioFixtures.tone(seconds: 0.5))
        try AudioFixtures.writeTrack(
            AudioFixtures.tone(seconds: 0.5),
            to: directory.appendingPathComponent("mixed.m4a")
        )

        XCTAssertEqual(
            RecordedSessionAudio.inspect(directory: directory),
            .usable(tracks: [url(.microphone)])
        )
    }

    private func url(_ source: AudioSource) -> URL {
        RecordedSessionAudio.trackURL(for: source, in: directory)
    }

    private func write(_ source: AudioSource, _ buffer: AVAudioPCMBuffer) throws {
        try AudioFixtures.writeTrack(buffer, to: url(source))
    }
}
