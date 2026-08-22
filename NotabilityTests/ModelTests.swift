import XCTest
@testable import Notability

final class ModelTests: XCTestCase {
    func test_meeting_codable_roundtrip() throws {
        let chunk = TranscriptChunk(timestamp: 30.0, text: "Hello world")
        let item = ActionItem(id: UUID(), description: "Send report", assignee: "Alice", dueDate: "2026-05-10", isCompleted: false)
        let notes = MeetingNotes(summary: "Good call", actionItems: [item], keyDecisions: ["Ship it"])
        let meeting = Meeting(
            id: UUID(),
            title: "Test Meeting",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 3600,
            transcript: [chunk],
            notes: notes,
            notesGenerationError: nil
        )

        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)

        XCTAssertEqual(decoded.id, meeting.id)
        XCTAssertEqual(decoded.title, meeting.title)
        XCTAssertEqual(decoded.durationSeconds, 3600)
        XCTAssertEqual(decoded.transcript.first?.text, "Hello world")
        XCTAssertEqual(decoded.notes?.summary, "Good call")
        XCTAssertEqual(decoded.notes?.actionItems.first?.assignee, "Alice")
        XCTAssertEqual(decoded.notes?.keyDecisions.first, "Ship it")
    }

    func test_meeting_notes_nil_roundtrip() throws {
        let meeting = Meeting(id: UUID(), title: "Pending", date: Date(), durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: "API error")
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertNil(decoded.notes)
        XCTAssertEqual(decoded.notesGenerationError, "API error")
    }

    /// Transcription stopped being user-selectable, so a stored model name can
    /// only describe something the app no longer runs.
    func test_legacy_transcription_selection_keys_are_cleared() throws {
        let defaults = try makeIsolatedUserDefaults()
        defaults.set("gpt4oTranscribe", forKey: "transcriptionMethod")
        defaults.set("gpt-realtime-whisper", forKey: "transcriptionModel")
        defaults.set("audioAPI", forKey: "transcriptionProvider")

        _ = ModelSettings(userDefaults: defaults)

        XCTAssertNil(defaults.object(forKey: "transcriptionMethod"))
        XCTAssertNil(defaults.object(forKey: "transcriptionModel"))
        XCTAssertNil(defaults.object(forKey: "transcriptionProvider"))
    }

    /// The settings the rewrite kept must survive the cleanup above.
    func test_surviving_settings_are_restored_from_defaults() throws {
        let defaults = try makeIsolatedUserDefaults()
        defaults.set("transcriptionMethod", forKey: "transcriptionMethod")
        defaults.set("gpt-4o-mini", forKey: "noteModel")
        defaults.set("ja", forKey: "transcriptionLanguage")
        defaults.set("Be terse.", forKey: "noteInstructions")

        let settings = ModelSettings(userDefaults: defaults)

        XCTAssertEqual(settings.noteModel, "gpt-4o-mini")
        XCTAssertEqual(settings.transcriptionLanguage, "ja")
        XCTAssertEqual(settings.noteInstructions, "Be terse.")
        XCTAssertEqual(settings.effectiveTranscriptionLocaleIdentifier, "ja")
    }

    private func makeIsolatedUserDefaults() throws -> UserDefaults {
        let suiteName = "ModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class ModelMigrationTests: XCTestCase {
    func test_transcriptChunk_decodes_legacy_json_without_speaker() throws {
        let legacy = Data(#"{"timestamp":12.5,"text":"안녕하세요"}"#.utf8)
        let chunk = try JSONDecoder().decode(TranscriptChunk.self, from: legacy)
        XCTAssertEqual(chunk.timestamp, 12.5)
        XCTAssertEqual(chunk.text, "안녕하세요")
        XCTAssertNil(chunk.speaker)
    }

    func test_transcriptChunk_roundtrips_with_speaker() throws {
        let original = TranscriptChunk(timestamp: 3, text: "네", speaker: "나")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptChunk.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The diarization API's segment list is used verbatim, so two segments can
    /// share a start time. Timestamps were the `ForEach` id until this existed.
    func test_identifiedRows_are_unique_when_timestamps_repeat() {
        let chunks = [
            TranscriptChunk(timestamp: 4, text: "overlapping", speaker: "A"),
            TranscriptChunk(timestamp: 4, text: "at the same instant", speaker: "B"),
            TranscriptChunk(timestamp: 4, text: "and a third", speaker: "A"),
        ]

        let ids = chunks.identifiedRows().map(\.id)

        XCTAssertEqual(ids, [0, 1, 2])
        XCTAssertEqual(Set(ids).count, chunks.count)
    }

    func test_identifiedRows_preserves_order_and_chunks() {
        let chunks = [
            TranscriptChunk(timestamp: 0, text: "first"),
            TranscriptChunk(timestamp: 9, text: "second"),
        ]

        XCTAssertEqual(chunks.identifiedRows().map(\.chunk), chunks)
    }

    /// Live captions append, and the identity of already-visible rows must not
    /// move when they do, or SwiftUI rebuilds rows the user is already reading.
    func test_identifiedRows_keep_their_ids_when_a_row_is_appended() {
        let existing = [
            TranscriptChunk(timestamp: 0, text: "first"),
            TranscriptChunk(timestamp: 5, text: "second"),
        ]

        let before = existing.identifiedRows()
        let after = (existing + [TranscriptChunk(timestamp: 8, text: "third")]).identifiedRows()

        XCTAssertEqual(Array(after.prefix(2)), before)
        XCTAssertEqual(after.last?.id, 2)
    }

    func test_identifiedRows_is_empty_for_empty_transcript() {
        XCTAssertTrue([TranscriptChunk]().identifiedRows().isEmpty)
    }

    func test_displaySpeaker_is_nil_when_there_is_nothing_to_attribute() {
        XCTAssertNil(TranscriptChunk(timestamp: 0, text: "t", speaker: nil).displaySpeaker)
        XCTAssertNil(TranscriptChunk(timestamp: 0, text: "t", speaker: "").displaySpeaker)
        XCTAssertNil(TranscriptChunk(timestamp: 0, text: "t", speaker: "  \n ").displaySpeaker)
    }

    func test_displaySpeaker_returns_the_label_when_present() {
        XCTAssertEqual(TranscriptChunk(timestamp: 0, text: "t", speaker: "나").displaySpeaker, "나")
        XCTAssertEqual(TranscriptChunk(timestamp: 0, text: "t", speaker: "Speaker A").displaySpeaker, "Speaker A")
    }

    /// Whatever the label check accepted is what must be rendered and copied, or
    /// a padded label draws a pill full of whitespace.
    func test_displaySpeaker_trims_surrounding_whitespace() {
        XCTAssertEqual(TranscriptChunk(timestamp: 0, text: "t", speaker: " 나 ").displaySpeaker, "나")
        XCTAssertEqual(
            TranscriptChunk(timestamp: 0, text: "t", speaker: "\nSpeaker A\t").displaySpeaker,
            "Speaker A"
        )
    }

    /// A blank speaker must not produce a dangling `:` in the clipboard while the
    /// transcript view shows no label for the same segment.
    func test_formattedForCopy_omits_blank_speakers() {
        let chunks = [
            TranscriptChunk(timestamp: 65, text: "labelled", speaker: "나"),
            TranscriptChunk(timestamp: 70, text: "blank", speaker: "   "),
            TranscriptChunk(timestamp: 75, text: "absent", speaker: nil),
        ]

        XCTAssertEqual(
            chunks.formattedForCopy(),
            "[1:05] 나: labelled\n[1:10] blank\n[1:15] absent"
        )
    }

    func test_meeting_decodes_legacy_json_without_new_fields() throws {
        let legacy = Data("""
        {"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","title":"Old meeting",
         "date":0,"durationSeconds":60,"transcript":[],"notes":null,
         "notesGenerationError":null}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let meeting = try decoder.decode(Meeting.self, from: legacy)
        XCTAssertEqual(meeting.title, "Old meeting")
        XCTAssertNil(meeting.audioDirectory)
        XCTAssertNil(meeting.transcriptionError)
        XCTAssertNil(meeting.billedSeconds)
    }
}
