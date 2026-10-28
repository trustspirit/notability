import XCTest
@testable import Notability

final class NoteGenerationServiceTests: XCTestCase {
    private let credentialKey = "com.notability.openai-api-key"
    private let anthropicKey = "com.notability.anthropic-api-key"
    private var sandbox: CredentialStoreSandbox!

    override func setUp() async throws {
        sandbox = CredentialStoreSandbox()
        CredentialsStore.save("sk-test", forKey: credentialKey)
    }

    override func tearDown() async throws {
        CredentialsStore.delete(forKey: credentialKey)
        CredentialsStore.delete(forKey: anthropicKey)
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
        let sut = NoteGenerationService(httpClient: client, model: { "gpt-5.5" })

        let transcript = [TranscriptChunk(timestamp: 0, text: "Let's discuss Q2.")]
        let notes = try await sut.generateNotes(transcript: transcript)

        XCTAssertEqual(notes.summary, "Discussed Q2 roadmap.")
        XCTAssertEqual(notes.actionItems.first?.description, "Write spec")
        XCTAssertEqual(notes.actionItems.first?.assignee, "Bob")
        XCTAssertEqual(notes.keyDecisions.first, "Ship in June")
    }

    func test_throws_on_invalid_json() async throws {
        let client = MockHTTPClient(responseData: "not json".data(using: .utf8)!, statusCode: 200)
        let sut = NoteGenerationService(httpClient: client, model: { "gpt-5.5" })

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

    private func makeSUT(
        _ client: HTTPClient,
        maxAttempts: Int = 3,
        model: String = "gpt-5.5"
    ) -> NoteGenerationService {
        NoteGenerationService(
            httpClient: client,
            retryPolicy: RetryPolicy(maxAttempts: maxAttempts, baseDelay: 0.001, maxDelay: 0.001),
            sleep: { _ in },
            model: { model }
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


    // MARK: - Claude

    private func message(
        text: String,
        stopReason: String = "end_turn",
        leadingBlocks: [[String: Any]] = []
    ) -> Data {
        let body: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": leadingBlocks + [["type": "text", "text": text]],
            "stop_reason": stopReason
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func requestBody(_ client: MockHTTPClient) throws -> [String: Any] {
        let body = try XCTUnwrap(client.requests.first?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func test_a_claude_model_is_sent_to_the_messages_api_with_its_own_key() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(responseData: message(text: Self.notesJSON), statusCode: 200)

        let notes = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [
            TranscriptChunk(timestamp: 0, text: "hi", speaker: "A")
        ])

        XCTAssertEqual(notes.summary, "S")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), NoteGenerationService.anthropicVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the OpenAI key must not travel to Anthropic")

        let body = try requestBody(client)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, NoteGenerationService.anthropicMaxTokens)
        XCTAssertNotNil(body["system"] as? String)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "[00:00] A: hi")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"] as? [String: Any])
    }

    /// A declined request is re-run on another model inside the same call,
    /// rather than costing the meeting its notes.
    func test_a_model_that_supports_it_opts_into_server_side_fallback() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(responseData: message(text: Self.notesJSON), statusCode: 200)

        _ = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])

        XCTAssertEqual(try requestBody(client)["fallbacks"] as? String, "default")
        XCTAssertEqual(
            client.requests.first?.value(forHTTPHeaderField: "anthropic-beta"),
            NoteGenerationService.anthropicFallbackBeta
        )
    }

    /// Any other model rejects the parameter with a 400.
    func test_a_model_without_server_side_fallback_is_not_sent_it() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(responseData: message(text: Self.notesJSON), statusCode: 200)

        _ = try await makeSUT(client, model: "claude-haiku-5-5").generateNotes(transcript: [])

        XCTAssertNil(try requestBody(client)["fallbacks"])
        XCTAssertNil(client.requests.first?.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func test_thinking_and_fallback_blocks_before_the_notes_are_skipped() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(
            responseData: message(text: Self.notesJSON, leadingBlocks: [
                ["type": "thinking", "thinking": "", "signature": "x"],
                ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-4-8"]]
            ]),
            statusCode: 200
        )

        let notes = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])

        XCTAssertEqual(notes.keyDecisions, ["D"])
    }

    func test_a_refusal_fails_without_retrying_or_parsing() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(responseData: message(text: "", stopReason: "refusal"), statusCode: 200)

        do {
            _ = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? NoteGenerationService.APIError, .refused)
            XCTAssertEqual(client.requestCount, 1)
        }
    }

    func test_a_claude_answer_cut_off_at_max_tokens_is_retried() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(stubs: [
            .init(data: message(text: "{\"summary", stopReason: "max_tokens"), statusCode: 200),
            .init(data: message(text: Self.notesJSON), statusCode: 200)
        ])

        _ = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])

        XCTAssertEqual(client.requestCount, 2)
    }

    /// 529 is Anthropic's "overloaded", which is worth waiting out.
    func test_an_overloaded_response_is_retried() async throws {
        CredentialsStore.save("sk-ant-test", forKey: anthropicKey)
        let client = MockHTTPClient(stubs: [
            .init(data: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8), statusCode: 529),
            .init(data: message(text: Self.notesJSON), statusCode: 200)
        ])

        _ = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])

        XCTAssertEqual(client.requestCount, 2)
    }

    func test_a_claude_model_without_an_anthropic_key_names_the_missing_key() async throws {
        let client = MockHTTPClient(responseData: message(text: Self.notesJSON), statusCode: 200)

        do {
            _ = try await makeSUT(client, model: "claude-opus-5-5").generateNotes(transcript: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? NoteGenerationService.APIError, .missingAPIKey(.anthropic))
            XCTAssertEqual(client.requestCount, 0, "nothing may be sent without the key")
        }
    }

    func test_the_provider_is_read_off_the_model_name() {
        XCTAssertEqual(NoteModelProvider(model: "claude-opus-5-5"), .anthropic)
        XCTAssertEqual(NoteModelProvider(model: "Claude-Sonnet-5-5"), .anthropic)
        XCTAssertEqual(NoteModelProvider(model: "gpt-5.5"), .openAI)
        XCTAssertEqual(NoteModelProvider(model: "o4-mini"), .openAI)
    }

}
