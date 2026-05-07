import XCTest
@testable import MeetingScribe

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
}
