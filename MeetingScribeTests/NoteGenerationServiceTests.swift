import XCTest
@testable import MeetingScribe

final class NoteGenerationServiceTests: XCTestCase {
    private let keychainKey = "com.meetingscribe.openai-api-key"

    override func setUp() async throws {
        KeychainHelper.save("sk-test", forKey: keychainKey)
    }

    override func tearDown() async throws {
        KeychainHelper.delete(forKey: keychainKey)
    }

    func test_generates_notes_from_transcript() async throws {
        let json = """
        {
          "summary": "Discussed Q2 roadmap.",
          "action_items": [
            { "description": "Write spec", "assignee": "Bob", "due_date": "2026-05-15" }
          ],
          "key_decisions": ["Ship in June"]
        }
        """
        let client = MockHTTPClient(responseData: json.data(using: .utf8)!, statusCode: 200)
        let sut = NoteGenerationService(httpClient: client)

        let transcript = [TranscriptChunk(timestamp: 0, text: "Let's discuss Q2.")]
        let notes = try await sut.generateNotes(transcript: transcript)

        XCTAssertEqual(notes.summary, "Discussed Q2 roadmap.")
        XCTAssertEqual(notes.actionItems.first?.description, "Write spec")
        XCTAssertEqual(notes.actionItems.first?.assignee, "Bob")
        XCTAssertEqual(notes.keyDecisions.first, "Ship in June")
    }

    func test_throws_on_invalid_json() async throws {
        let client = MockHTTPClient(responseData: "not json".data(using: .utf8)!, statusCode: 200)
        let sut = NoteGenerationService(httpClient: client)

        do {
            _ = try await sut.generateNotes(transcript: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is NoteGenerationService.APIError || error is DecodingError)
        }
    }
}
