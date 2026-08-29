import XCTest
@testable import Notability

/// Microphone-only recording was reachable before this mode existed, but only
/// by losing Screen Recording permission. These cover the difference between
/// choosing it and suffering it.
final class RecordingModeTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "RecordingModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    // MARK: - Persistence

    func test_mode_defaults_to_capturing_everything() {
        withDefaults { defaults in
            XCTAssertEqual(ModelSettings(userDefaults: defaults).recordingMode, .microphoneAndSystem)
        }
    }

    func test_mode_persists_across_settings_instances() {
        withDefaults { defaults in
            ModelSettings(userDefaults: defaults).recordingMode = .microphoneOnly

            XCTAssertEqual(ModelSettings(userDefaults: defaults).recordingMode, .microphoneOnly)
        }
    }

    func test_an_unreadable_stored_mode_falls_back_to_capturing_everything() {
        withDefaults { defaults in
            defaults.set("something-a-later-version-wrote", forKey: "recordingMode")

            // Recording less than the user expects is the worse failure: the
            // half of the meeting that went uncaptured cannot be recovered.
            XCTAssertEqual(ModelSettings(userDefaults: defaults).recordingMode, .microphoneAndSystem)
        }
    }

    // MARK: - Speaker reference

    /// The extractor looks for a stretch where the microphone has speech and the
    /// system track is silent, and calls that the local user. With no system
    /// track the second half of that test is vacuously true, so in an in-person
    /// meeting the first person to talk becomes "the local user" for the whole
    /// transcript — including when that is someone else.
    func test_no_speaker_reference_is_taken_from_a_deliberately_microphone_only_recording() {
        XCTAssertFalse(
            RecordingCoordinator.shouldExtractSpeakerReference(mode: .microphoneOnly)
        )
    }

    /// Losing Screen Recording is not the same situation: the meeting still had
    /// a far end, it just reached the microphone through the speakers, so the
    /// microphone track is still the local user's and worth referencing — which
    /// is why this turns on the mode and not on whether a track was written.
    func test_a_recording_that_wanted_system_audio_and_lost_it_still_takes_a_reference() {
        XCTAssertTrue(
            RecordingCoordinator.shouldExtractSpeakerReference(mode: .microphoneAndSystem)
        )
    }

}
