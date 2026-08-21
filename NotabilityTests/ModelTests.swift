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

    func test_transcription_methods_expose_only_realtime_whisper_and_gpt4o_transcribe() {
        XCTAssertEqual(
            ModelSettings.TranscriptionMethod.allCases.map(\.model),
            ["gpt-realtime-whisper", "gpt-4o-transcribe"]
        )
    }

    func test_legacy_whisper_saved_setting_migrates_to_gpt4o_transcribe_method() throws {
        let defaults = try makeIsolatedUserDefaults()
        defaults.set("audioAPI", forKey: "transcriptionProvider")
        defaults.set("whisper-1", forKey: "transcriptionModel")

        let settings = ModelSettings(userDefaults: defaults)

        XCTAssertEqual(settings.transcriptionMethod, .gpt4oTranscribe)
        XCTAssertEqual(settings.transcriptionModel, "gpt-4o-transcribe")
    }

    func test_saved_realtime_model_migrates_to_realtime_whisper_method() throws {
        let defaults = try makeIsolatedUserDefaults()
        defaults.set("audioAPI", forKey: "transcriptionProvider")
        defaults.set("gpt-realtime-whisper", forKey: "transcriptionModel")

        let settings = ModelSettings(userDefaults: defaults)

        XCTAssertEqual(settings.transcriptionMethod, .realtimeWhisper)
        XCTAssertEqual(settings.transcriptionModel, "gpt-realtime-whisper")
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
