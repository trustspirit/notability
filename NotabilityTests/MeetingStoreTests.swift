// NotabilityTests/MeetingStoreTests.swift
import XCTest
import AVFoundation
import Combine
@testable import Notability

final class MeetingStoreTests: XCTestCase {
    var sut: MeetingStore!
    var root: URL!
    var tempDir: URL!
    var audioRoot: URL!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDir = root.appendingPathComponent("meetings")
        audioRoot = root.appendingPathComponent("audio")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        sut = makeStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeStore() -> MeetingStore {
        MeetingStore(storageDirectory: tempDir, audioRootDirectory: audioRoot)
    }

    func test_save_and_fetch() {
        let meeting = makeMeeting(title: "Alpha")
        sut.save(meeting)
        XCTAssertEqual(sut.fetch(id: meeting.id)?.title, "Alpha")
    }

    func test_all_returns_sorted_by_date_descending() {
        let early = makeMeeting(title: "Early", date: Date(timeIntervalSince1970: 100))
        let late  = makeMeeting(title: "Late",  date: Date(timeIntervalSince1970: 200))
        sut.save(early)
        sut.save(late)
        let all = sut.allMeetings
        XCTAssertEqual(all.first?.title, "Late")
    }

    func test_delete_removes_meeting() {
        let meeting = makeMeeting(title: "ToDelete")
        sut.save(meeting)
        sut.delete(id: meeting.id)
        XCTAssertNil(sut.fetch(id: meeting.id))
    }

    func test_persists_across_instances() {
        let meeting = makeMeeting(title: "Persisted")
        sut.save(meeting)

        let sut2 = makeStore()
        XCTAssertEqual(sut2.fetch(id: meeting.id)?.title, "Persisted")
    }

    // MARK: - Field-level updates

    /// The post-processing pipeline holds a meeting across minutes of network
    /// I/O while the detail view's title field stays on screen. Writing back
    /// what it read reverted the rename; this is the call site that cannot.
    func test_update_writes_only_the_fields_it_touches() {
        // `stale` is what a caller that suspended before the rename still holds.
        let stale = makeMeeting(title: "Original")
        sut.save(stale)
        sut.rename(id: stale.id, title: "Renamed")

        sut.update(id: stale.id) {
            $0.transcript = [TranscriptChunk(timestamp: 0, text: "text")]
        }

        let stored = sut.fetch(id: stale.id)
        XCTAssertEqual(stored?.title, "Renamed", "update() must not carry a stale title back")
        XCTAssertEqual(stored?.transcript.count, 1)
    }

    func test_update_does_nothing_for_a_deleted_meeting() {
        let id = UUID()
        sut.update(id: id) { $0.title = "Ghost" }
        XCTAssertNil(sut.fetch(id: id))
        XCTAssertTrue(sut.allMeetings.isEmpty)
    }

    // MARK: - Audio directory lifecycle

    func test_deleting_a_meeting_deletes_its_audio() throws {
        var meeting = makeMeeting(title: "Failed and unwanted")
        meeting.transcriptionError = "rate limited"
        let directory = try makeAudioDirectory(for: meeting.id)
        meeting.audioDirectory = directory
        sut.save(meeting)

        sut.delete(id: meeting.id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "A deleted meeting will never be retried, so its audio is roughly 33 MB per hour that nothing would reclaim"
        )
    }

    /// A meeting whose audio claim was already cleared can still have a
    /// directory left over from an earlier delete that failed.
    func test_deleting_a_meeting_deletes_leftover_audio_it_no_longer_claims() throws {
        let meeting = makeMeeting(title: "Notes done")
        let directory = try makeAudioDirectory(for: meeting.id)
        sut.save(meeting)
        XCTAssertNil(meeting.audioDirectory)

        sut.delete(id: meeting.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_launch_reclaims_audio_no_meeting_refers_to() throws {
        // What a crash during recording leaves once its meeting has been
        // deleted, and what every pre-fix crash left behind.
        let orphan = try makeAudioDirectory(for: UUID())

        _ = makeStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// The audio is kept precisely so a failure can be retried. Reclaiming it
    /// would be a worse defect than the leak.
    func test_launch_keeps_audio_for_a_meeting_awaiting_retry() throws {
        var meeting = makeMeeting(title: "Rate limited")
        meeting.transcriptionError = "OpenAI rate limit or quota exceeded (HTTP 429)."
        let directory = try makeAudioDirectory(for: meeting.id)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = makeStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(reloaded.fetch(id: meeting.id)?.audioDirectory, directory)
    }

    /// A meeting that was mid-pipeline when the process died still holds its
    /// claim, and the sweep runs against the same claims.
    func test_launch_keeps_audio_for_a_meeting_that_was_mid_processing() throws {
        var meeting = makeMeeting(title: "Was transcribing")
        // Post-processing only starts after the recording's files are closed,
        // so a meeting interrupted mid-pipeline has readable audio.
        let directory = try makeAudioDirectory(for: meeting.id, tracks: .readable)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = makeStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(reloaded.fetch(id: meeting.id)?.audioDirectory)
    }

    func test_launch_keeps_audio_for_a_meeting_that_only_needs_notes() throws {
        var meeting = makeMeeting(title: "Transcribed, no notes")
        meeting.transcript = [TranscriptChunk(timestamp: 0, text: "Already paid for")]
        let directory = try makeAudioDirectory(for: meeting.id, tracks: .readable)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = makeStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(reloaded.fetch(id: meeting.id)?.audioDirectory)
    }

    /// The sweep only claims directories named after a meeting, so anything else
    /// that ends up in the audio root is left alone.
    func test_launch_leaves_entries_that_are_not_meeting_directories_alone() throws {
        let stray = audioRoot.appendingPathComponent("not-a-uuid")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let file = audioRoot.appendingPathComponent("\(UUID().uuidString)")
        try Data("loose".utf8).write(to: file)

        _ = makeStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// The sweep decides from the claims the records carry. Reading no records
    /// because the directory was unreadable is not the same as there being no
    /// claims, and acting as if it were would delete every user's audio at once.
    func test_launch_reclaims_nothing_when_the_records_cannot_be_read() throws {
        var meeting = makeMeeting(title: "Awaiting retry")
        meeting.transcriptionError = "rate limited"
        let directory = try makeAudioDirectory(for: meeting.id)
        meeting.audioDirectory = directory
        sut.save(meeting)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: tempDir.path
        )
        addTeardownBlock { [tempDir] in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempDir!.path
            )
        }

        let reloaded = makeStore()

        XCTAssertTrue(reloaded.allMeetings.isEmpty, "The records really were unreadable")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "Audio must not be reclaimed on the strength of claims that were never loaded"
        )
    }

    // MARK: - Interrupted meetings

    func test_interrupted_before_transcription_says_the_audio_was_kept() throws {
        var meeting = makeMeeting(title: "Interrupted")
        let directory = try makeAudioDirectory(for: meeting.id, tracks: .readable)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = try XCTUnwrap(makeStore().fetch(id: meeting.id))

        XCTAssertEqual(
            reloaded.transcriptionError,
            ProcessingStatusMessage.interruptedBeforeTranscription
        )
        XCTAssertNil(reloaded.notesGenerationError)
        XCTAssertTrue(reloaded.canRetryProcessing, "The message tells the user to retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The defect: a meeting that died during note generation has a complete
    /// transcript and has already been charged for it, and was being told it was
    /// never transcribed.
    func test_interrupted_after_transcription_reports_the_notes_stage_instead() throws {
        var meeting = makeMeeting(title: "Interrupted")
        meeting.transcript = [TranscriptChunk(timestamp: 12, text: "Already saved transcript")]
        let directory = try makeAudioDirectory(for: meeting.id, tracks: .readable)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = try XCTUnwrap(makeStore().fetch(id: meeting.id))

        XCTAssertEqual(reloaded.transcript, meeting.transcript)
        XCTAssertNil(
            reloaded.transcriptionError,
            "It was transcribed and billed for; saying otherwise is what makes the user afraid to retry"
        )
        XCTAssertEqual(
            reloaded.notesGenerationError,
            ProcessingStatusMessage.interruptedBeforeNotes
        )
        XCTAssertTrue(reloaded.canRetryProcessing)
    }

    func test_the_notes_stage_message_says_retrying_is_not_charged_again() {
        let message = ProcessingStatusMessage.interruptedBeforeNotes
        XCTAssertTrue(message.contains("already been charged"))
        XCTAssertTrue(message.contains("not charged again"))
        XCTAssertFalse(
            message.lowercased().contains("could not be transcribed"),
            "The transcript is saved — this is exactly the claim that was false"
        )
    }

    /// The other half of the defect: audio a decoder cannot open makes Retry
    /// fail identically forever, so no Retry is offered and the files go.
    func test_interrupted_with_unreadable_audio_offers_no_retry_and_reclaims_the_audio() throws {
        var meeting = makeMeeting(title: "Force quit")
        let directory = try makeAudioDirectory(for: meeting.id, tracks: .unfinalized)
        meeting.audioDirectory = directory
        sut.save(meeting)

        let reloaded = try XCTUnwrap(makeStore().fetch(id: meeting.id))

        XCTAssertEqual(reloaded.transcriptionError, ProcessingStatusMessage.unreadableAudio)
        XCTAssertNil(reloaded.audioDirectory)
        XCTAssertFalse(
            reloaded.canRetryProcessing,
            "Offering a Retry that fails the same way every time is the lie this fixes"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_interrupted_with_no_audio_on_disk_says_so() throws {
        var meeting = makeMeeting(title: "Nothing captured")
        meeting.audioDirectory = audioRoot.appendingPathComponent(meeting.id.uuidString)
        sut.save(meeting)

        let reloaded = try XCTUnwrap(makeStore().fetch(id: meeting.id))

        XCTAssertEqual(reloaded.transcriptionError, ProcessingStatusMessage.missingAudio)
        XCTAssertFalse(reloaded.canRetryProcessing)
    }

    func test_the_unrecoverable_messages_never_ask_for_a_retry() {
        for message in [ProcessingStatusMessage.unreadableAudio, ProcessingStatusMessage.missingAudio] {
            XCTAssertFalse(
                message.contains("Retry"),
                "No Retry button is shown for these, so none may be named: \(message)"
            )
        }
    }

    /// The detail view titles its error pane from this. An interruption reported
    /// as a failure says a stage ran when it never started.
    func test_every_interruption_is_marked_as_one_rather_than_as_a_failure() throws {
        var interruptedBeforeTranscription = makeMeeting(title: "Crashed")
        interruptedBeforeTranscription.audioDirectory =
            try makeAudioDirectory(for: interruptedBeforeTranscription.id, tracks: .readable)

        var interruptedBeforeNotes = makeMeeting(title: "Crashed later")
        interruptedBeforeNotes.transcript = [TranscriptChunk(timestamp: 0, text: "본문")]

        var forceQuit = makeMeeting(title: "Force quit")
        forceQuit.audioDirectory = try makeAudioDirectory(for: forceQuit.id, tracks: .unfinalized)

        for meeting in [interruptedBeforeTranscription, interruptedBeforeNotes, forceQuit] {
            sut.save(meeting)
        }

        let reloaded = makeStore()
        for meeting in [interruptedBeforeTranscription, interruptedBeforeNotes, forceQuit] {
            XCTAssertEqual(
                reloaded.fetch(id: meeting.id)?.processingWasInterrupted,
                true,
                "\(meeting.title) stopped because the app did, not because a stage failed"
            )
        }
    }

    func test_a_recorded_failure_is_not_marked_as_an_interruption() throws {
        var meeting = makeMeeting(title: "Rate limited")
        meeting.transcriptionError = "OpenAI rate limit or quota exceeded (HTTP 429)."
        sut.save(meeting)

        XCTAssertEqual(makeStore().fetch(id: meeting.id)?.processingWasInterrupted, false)
    }

    /// Reloading must not overwrite a failure the pipeline already recorded —
    /// the meeting would then say it was interrupted instead of saying it was
    /// rate limited, and the reason to retry would be lost.
    func test_reload_keeps_a_recorded_transcription_failure() {
        var meeting = makeMeeting(title: "Rate limited")
        meeting.transcriptionError = "OpenAI rate limit or quota exceeded (HTTP 429)."
        sut.save(meeting)

        let sut2 = makeStore()

        XCTAssertEqual(
            sut2.fetch(id: meeting.id)?.transcriptionError,
            "OpenAI rate limit or quota exceeded (HTTP 429)."
        )
    }

    func test_reload_keeps_a_recorded_note_generation_failure() {
        var meeting = makeMeeting(title: "Notes failed")
        meeting.notesGenerationError = "notes exploded"
        sut.save(meeting)

        let sut2 = makeStore()
        let reloaded = sut2.fetch(id: meeting.id)

        XCTAssertEqual(reloaded?.notesGenerationError, "notes exploded")
        XCTAssertNil(reloaded?.transcriptionError)
    }

    func test_a_finished_meeting_is_left_alone() throws {
        var meeting = makeMeeting(title: "Done")
        meeting.notes = MeetingNotes(summary: "Summary", actionItems: [], keyDecisions: [])
        sut.save(meeting)

        let reloaded = try XCTUnwrap(makeStore().fetch(id: meeting.id))

        XCTAssertNil(reloaded.transcriptionError)
        XCTAssertNil(reloaded.notesGenerationError)
        XCTAssertFalse(reloaded.canRetryProcessing)
    }

    func test_meetings_publisher_emits_on_save() {
        let expectation = expectation(description: "publisher emits")
        var received: [Meeting] = []

        sut.$allMeetings
            .dropFirst()
            .sink { meetings in
                received = meetings
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.save(makeMeeting(title: "New"))
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received.first?.title, "New")
    }

    private func makeMeeting(title: String, date: Date = Date()) -> Meeting {
        Meeting(id: UUID(), title: title, date: date, durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
    }

    private enum TrackState {
        /// No track files, only the directory — enough for the sweep, which
        /// looks at names rather than contents.
        case none
        /// Closed containers, the way a recording that stopped normally leaves them.
        case readable
        /// Containers a process died with open, which no decoder will accept.
        case unfinalized
    }

    @discardableResult
    private func makeAudioDirectory(for id: UUID, tracks: TrackState = .none) throws -> URL {
        let directory = audioRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in AudioSource.allCases {
            let url = RecordedSessionAudio.trackURL(for: source, in: directory)
            switch tracks {
            case .none:
                try Data("audio".utf8).write(to: url)
            case .readable:
                try AudioFixtures.writeTrack(AudioFixtures.tone(seconds: 0.5), to: url)
            case .unfinalized:
                try AudioFixtures.writeUnfinalizedTrack(AudioFixtures.tone(seconds: 0.5), to: url)
            }
        }
        return directory
    }
}
