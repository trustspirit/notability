import XCTest
@testable import Notability

/// The prompt is the one place the app makes a promise about a recording it is
/// about to leave behind, and the previous version of it promised to discard a
/// session it in fact kept. These assert the promise and the behaviour together,
/// which is the only way the two cannot drift apart again.
final class QuitPolicyTests: XCTestCase {

    // MARK: - Nothing in flight

    func test_quitting_while_idle_does_not_ask() {
        XCTAssertEqual(QuitPolicy.decision(for: .idle), .quitNow)
    }

    func test_quitting_after_a_finished_meeting_does_not_ask() {
        XCTAssertEqual(QuitPolicy.decision(for: .done(meetingId: UUID())), .quitNow)
        XCTAssertEqual(QuitPolicy.decision(for: .failed("rate limited")), .quitNow)
    }

    // MARK: - Recording

    func test_quitting_while_recording_offers_processing_saving_and_carrying_on() throws {
        let prompt = try prompt(for: .recording(elapsed: 90))

        XCTAssertEqual(
            prompt.choices.map(\.buttonTitle),
            ["Stop & Generate Notes", "Save Audio & Quit", "Continue Recording"]
        )
    }

    /// No button may claim to discard the session, because nothing on this path
    /// does. The recording is kept for Retry either way, which is what the
    /// replaced "Quit Without Saving" said it was not.
    func test_no_recording_choice_claims_to_discard_the_session() throws {
        let prompt = try prompt(for: .recording(elapsed: 90))
        let text = prompt.informativeText + " " + prompt.choices.map(\.buttonTitle).joined(separator: " ")

        for claim in ["discard", "discarded", "without saving", "delete", "deleted", "lose", "lost"] {
            XCTAssertFalse(
                contains(word: claim, in: text),
                "The prompt says \"\(claim)\" but every choice keeps the recording"
            )
        }
    }

    func test_saving_the_audio_names_retry_as_what_happens_next() throws {
        let prompt = try prompt(for: .recording(elapsed: 90))

        XCTAssertTrue(prompt.informativeText.contains("Save Audio & Quit"))
        XCTAssertTrue(
            prompt.informativeText.contains("Retry"),
            "Quitting leaves the meeting untranscribed, so the user has to be told what finishes it"
        )
    }

    func test_the_recording_choices_do_what_their_titles_say() {
        XCTAssertEqual(
            QuitChoice.processRecordingThenQuit.effect,
            .quitAfter(.stopRecordingAndProcess)
        )
        XCTAssertEqual(
            QuitChoice.saveRecordedAudioThenQuit.effect,
            .quitAfter(.saveRecordedAudio),
            "Quitting must close the audio files, or the recording it saved cannot be read"
        )
        XCTAssertEqual(QuitChoice.continueRecording.effect, .cancelQuit)
    }

    // MARK: - Transcribing

    /// The paid pass is charged whether or not its result arrives, so quitting
    /// costs a second charge for the same recording. Not saying so was the defect.
    func test_quitting_mid_transcription_asks_and_says_it_costs_a_second_charge() throws {
        let prompt = try prompt(for: .transcribing(meetingId: UUID()))

        XCTAssertEqual(prompt.choices.map(\.buttonTitle), ["Keep Transcribing", "Quit Anyway"])
        XCTAssertTrue(prompt.informativeText.contains("already been charged"))
        XCTAssertTrue(prompt.informativeText.contains("second charge"))
    }

    func test_the_default_choice_mid_transcription_keeps_the_request_it_paid_for() throws {
        let prompt = try prompt(for: .transcribing(meetingId: UUID()))

        XCTAssertEqual(prompt.choices.first, .keepTranscribing)
        XCTAssertEqual(QuitChoice.keepTranscribing.effect, .cancelQuit)
    }

    /// Quitting anyway leaves the meeting with readable audio and no transcript,
    /// so the audio really is kept and Retry really can transcribe it.
    func test_quitting_anyway_terminates_without_further_work() {
        XCTAssertEqual(QuitChoice.abandonProcessingAndQuit.effect, .quitNow)
    }

    // MARK: - Generating notes

    func test_quitting_mid_note_generation_asks_and_says_it_is_not_charged_again() throws {
        let prompt = try prompt(for: .generatingNotes(meetingId: UUID()))

        XCTAssertEqual(prompt.choices.map(\.buttonTitle), ["Keep Generating Notes", "Quit Anyway"])
        XCTAssertTrue(prompt.informativeText.contains("transcript is already"))
        XCTAssertTrue(
            prompt.informativeText.contains("without paying for the transcription a second time"),
            "The transcript is saved, so this is the one stage that is free to repeat"
        )
    }

    func test_note_generation_is_never_described_as_charged() throws {
        let prompt = try prompt(for: .generatingNotes(meetingId: UUID()))
        XCTAssertFalse(prompt.informativeText.contains("second charge"))
    }

    func test_the_default_choice_mid_note_generation_keeps_going() throws {
        let prompt = try prompt(for: .generatingNotes(meetingId: UUID()))

        XCTAssertEqual(prompt.choices.first, .keepGeneratingNotes)
        XCTAssertEqual(QuitChoice.keepGeneratingNotes.effect, .cancelQuit)
    }

    // MARK: - Helpers

    private func prompt(for state: RecordingState) throws -> QuitPrompt {
        guard case .ask(let prompt) = QuitPolicy.decision(for: state) else {
            XCTFail("Expected \(state) to ask before quitting, not quit outright")
            throw NoPrompt()
        }
        return prompt
    }

    private struct NoPrompt: Error {}

    /// Whole words only, so "closes" is not read as a claim to lose anything.
    private func contains(word: String, in text: String) -> Bool {
        text.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    // MARK: - Quitting already agreed to

    /// The first answer already decided what happens to the recording, and the
    /// work carrying it out is still running. Asking again would offer to
    /// discard what the user just chose to keep — and, before this existed,
    /// a second Quit while the first was in flight re-entered the prompt.
    func test_a_second_quit_request_does_not_ask_again() {
        for state in Self.everyState {
            XCTAssertEqual(
                QuitPolicy.decision(for: state, isQuitting: true),
                .alreadyQuitting,
                "\(state) prompted again while already quitting"
            )
        }
    }

    func test_not_quitting_yet_decides_from_the_state_as_before() {
        XCTAssertEqual(QuitPolicy.decision(for: .idle, isQuitting: false), .quitNow)
        guard case .ask = QuitPolicy.decision(for: .recording(elapsed: 12), isQuitting: false) else {
            return XCTFail("Recording should still prompt when no quit is in flight")
        }
    }

    private static var everyState: [RecordingState] {
        let id = UUID()
        return [
            .idle,
            .recording(elapsed: 12),
            .transcribing(meetingId: id),
            .generatingNotes(meetingId: id),
            .done(meetingId: id),
            .failed("rate limited")
        ]
    }
}
