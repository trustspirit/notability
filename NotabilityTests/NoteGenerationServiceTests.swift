import XCTest
@testable import Notability

final class NoteGenerationServiceTests: XCTestCase {
    private let credentialKey = "com.notability.openai-api-key"
    private var sandbox: CredentialStoreSandbox!

    override func setUp() async throws {
        sandbox = CredentialStoreSandbox()
        CredentialsStore.save("sk-test", forKey: credentialKey)
    }

    override func tearDown() async throws {
        CredentialsStore.delete(forKey: credentialKey)
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

    // MARK: - Long meetings

    private static let notesJSON = """
    {"summary":"S","action_items":[],"key_decisions":["D"]}
    """

    private func makeSUT(_ client: HTTPClient, maxAttempts: Int = 3) -> NoteGenerationService {
        NoteGenerationService(
            httpClient: client,
            retryPolicy: RetryPolicy(maxAttempts: maxAttempts, baseDelay: 0.001, maxDelay: 0.001),
            sleep: { _ in }
        )
    }

    private func completion(content: String, finishReason: String = "stop") -> Data {
        let body: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": finishReason]]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func test_a_server_error_is_retried() async throws {
        let client = MockHTTPClient(stubs: [
            .init(data: Data(), statusCode: 503),
            .init(data: completion(content: Self.notesJSON), statusCode: 200)
        ])

        let notes = try await makeSUT(client).generateNotes(transcript: [TranscriptChunk(timestamp: 0, text: "hi")])

        XCTAssertEqual(notes.summary, "S")
        XCTAssertEqual(client.requestCount, 2)
    }

    /// The request is not streamed, so a long meeting's notes arrive only once
    /// they are complete; a timeout is the commonest way they fail.
    func test_a_timeout_is_retried() async throws {
        let client = MockHTTPClient(stubs: [
            .init(error: URLError(.timedOut)),
            .init(data: completion(content: Self.notesJSON), statusCode: 200)
        ])

        _ = try await makeSUT(client).generateNotes(transcript: [TranscriptChunk(timestamp: 0, text: "hi")])

        XCTAssertEqual(client.requestCount, 2)
    }

    func test_a_client_error_is_not_retried() async throws {
        let client = MockHTTPClient(stubs: [
            .init(data: Data(), statusCode: 400),
            .init(data: completion(content: Self.notesJSON), statusCode: 200)
        ])

        do {
            _ = try await makeSUT(client).generateNotes(transcript: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(client.requestCount, 1)
        }
    }

    func test_cut_off_notes_are_requested_again_rather_than_parsed() async throws {
        let client = MockHTTPClient(stubs: [
            .init(data: completion(content: "{\"summary\":\"S", finishReason: "length"), statusCode: 200),
            .init(data: completion(content: Self.notesJSON), statusCode: 200)
        ])

        let notes = try await makeSUT(client).generateNotes(transcript: [])

        XCTAssertEqual(notes.keyDecisions, ["D"])
        XCTAssertEqual(client.requestCount, 2)
    }

    func test_the_request_waits_long_enough_for_a_long_meeting() async throws {
        let client = MockHTTPClient(responseData: completion(content: Self.notesJSON), statusCode: 200)

        _ = try await makeSUT(client).generateNotes(transcript: [])

        XCTAssertGreaterThanOrEqual(client.requests.first?.timeoutInterval ?? 0, 600)
    }

    /// Without the speaker the model cannot tell who owns an action item.
    func test_the_transcript_sent_carries_speakers_and_clock_times() async throws {
        let client = MockHTTPClient(responseData: completion(content: Self.notesJSON), statusCode: 200)
        let transcript = [
            TranscriptChunk(timestamp: 5, text: "Let's start.", speaker: "나"),
            TranscriptChunk(timestamp: 3_725, text: "I'll write it.", speaker: "B2"),
            TranscriptChunk(timestamp: 3_800, text: "Untagged.")
        ]

        _ = try await makeSUT(client).generateNotes(transcript: transcript)

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages.last?["content"] as? String,
            "[00:05] 나: Let's start.\n[1:02:05] B2: I'll write it.\n[1:03:20] Untagged."
        )
    }

    func test_the_schema_is_enforced_by_the_server() async throws {
        let client = MockHTTPClient(responseData: completion(content: Self.notesJSON), statusCode: 200)

        _ = try await makeSUT(client).generateNotes(transcript: [])

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["strict"] as? Bool, true)
    }

    /// A model that ignores the schema may send an empty list as null or leave
    /// it out; that must not cost the meeting its notes.
    func test_missing_or_null_lists_are_read_as_empty() async throws {
        let client = MockHTTPClient(
            responseData: completion(content: #"{"summary":"S","action_items":null}"#),
            statusCode: 200
        )

        let notes = try await makeSUT(client).generateNotes(transcript: [])

        XCTAssertEqual(notes.summary, "S")
        XCTAssertTrue(notes.actionItems.isEmpty)
        XCTAssertTrue(notes.keyDecisions.isEmpty)
    }

}
