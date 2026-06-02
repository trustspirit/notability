import XCTest
@testable import Notability

final class NoteGenerationServiceTests: XCTestCase {
    private let keychainKey = "com.notability.openai-api-key"
    private var sandbox: CredentialStoreSandbox!

    override func setUp() async throws {
        sandbox = CredentialStoreSandbox()
        CredentialsStore.save("sk-test", forKey: keychainKey)
    }

    override func tearDown() async throws {
        CredentialsStore.delete(forKey: keychainKey)
        sandbox.tearDown()
        sandbox = nil
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

    func test_summary_prompt_requests_a_rich_summary_without_a_two_to_three_sentence_cap() async throws {
        let json = """
        { "summary": "x", "action_items": [], "key_decisions": [] }
        """
        let client = MockHTTPClient(responseData: json.data(using: .utf8)!, statusCode: 200)
        let sut = NoteGenerationService(httpClient: client)

        _ = try await sut.generateNotes(transcript: [TranscriptChunk(timestamp: 0, text: "hi")])

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(
            bodyString.contains("2-3 sentence"),
            "Summary prompt should not cap the summary at 2-3 sentences"
        )
        XCTAssertTrue(
            bodyString.contains("comprehensive"),
            "Summary prompt should ask for a comprehensive summary"
        )
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
