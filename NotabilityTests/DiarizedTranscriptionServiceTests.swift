import XCTest
@testable import Notability

final class DiarizedTranscriptionServiceTests: XCTestCase {
    private let apiKeyName = "com.notability.openai-api-key"
    private var sandbox: CredentialStoreSandbox!
    private var audioURL: URL!

    override func setUpWithError() throws {
        sandbox = CredentialStoreSandbox()
        CredentialsStore.save("test-key", forKey: apiKeyName)
        audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("fake audio".utf8).write(to: audioURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audioURL)
        CredentialsStore.delete(forKey: apiKeyName)
        sandbox.tearDown()
        sandbox = nil
    }

    private static let successPayload = Data("""
    {"task":"transcribe","duration":27.4,
     "text":"나: 안녕하세요.\\nA: 반갑습니다.",
     "segments":[
       {"type":"transcript.text.segment","id":"seg_001","start":0.0,"end":4.7,
        "text":"안녕하세요.","speaker":"나"},
       {"type":"transcript.text.segment","id":"seg_002","start":4.7,"end":11.8,
        "text":"반갑습니다.","speaker":"A"}],
     "usage":{"type":"duration","seconds":27}}
    """.utf8)

    private func makeSUT(client: HTTPClient, maxAttempts: Int = 3) -> DiarizedTranscriptionService {
        DiarizedTranscriptionService(
            httpClient: client,
            retryPolicy: RetryPolicy(maxAttempts: maxAttempts, baseDelay: 0.001, maxDelay: 0.001),
            sleep: { _ in }
        )
    }

    // MARK: - Parsing

    func test_parses_segments_into_speaker_labelled_chunks() async throws {
        let client = MockHTTPClient(responseData: Self.successPayload, statusCode: 200)
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: "ko")

        XCTAssertEqual(result.chunks.count, 2)
        XCTAssertEqual(result.chunks[0].speaker, "나")
        XCTAssertEqual(result.chunks[0].text, "안녕하세요.")
        XCTAssertEqual(result.chunks[0].timestamp, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.chunks[1].speaker, "A")
        XCTAssertEqual(result.chunks[1].timestamp, 4.7, accuracy: 1e-9)
    }

    func test_reports_billed_seconds_from_usage() async throws {
        let client = MockHTTPClient(responseData: Self.successPayload, statusCode: 200)
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(result.billedSeconds, 27)
    }

    func test_sends_diarize_model_and_format() async throws {
        let client = MockHTTPClient(responseData: Self.successPayload, statusCode: 200)
        let sut = makeSUT(client: client)

        _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: "ko")

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("gpt-4o-transcribe-diarize"))
        XCTAssertTrue(text.contains("diarized_json"))
        XCTAssertTrue(text.contains("chunking_strategy"))
        XCTAssertTrue(text.contains("name=\"language\""))
    }

    func test_includes_speaker_reference_when_provided() async throws {
        let client = MockHTTPClient(responseData: Self.successPayload, statusCode: 200)
        let sut = makeSUT(client: client)

        _ = try await sut.transcribe(
            audioURL: audioURL,
            speakerReference: Data("reference".utf8),
            language: nil
        )

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("known_speaker_names[]"))
        XCTAssertTrue(text.contains("known_speaker_references[]"))
        XCTAssertTrue(text.contains("data:audio/wav;base64,"))
    }

    func test_omits_speaker_reference_fields_when_not_provided() async throws {
        let client = MockHTTPClient(responseData: Self.successPayload, statusCode: 200)
        let sut = makeSUT(client: client)

        _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        let body = try XCTUnwrap(client.requests.first?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("known_speaker_names[]"))
        XCTAssertFalse(text.contains("known_speaker_references[]"))
    }

    // MARK: - Boundary cases in the response payload

    func test_empty_segments_array_yields_no_chunks() async throws {
        let payload = Data("""
        {"task":"transcribe","duration":0,"text":"","segments":[],"usage":{"type":"duration","seconds":0}}
        """.utf8)
        let client = MockHTTPClient(responseData: payload, statusCode: 200)
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertTrue(result.chunks.isEmpty)
    }

    func test_missing_usage_yields_nil_billed_seconds() async throws {
        let payload = Data("""
        {"task":"transcribe","duration":4.7,"text":"안녕하세요.",
         "segments":[{"type":"transcript.text.segment","id":"seg_001","start":0.0,"end":4.7,
                       "text":"안녕하세요.","speaker":"나"}]}
        """.utf8)
        let client = MockHTTPClient(responseData: payload, statusCode: 200)
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertNil(result.billedSeconds)
    }

    func test_whitespace_only_segment_text_is_dropped() async throws {
        let payload = Data("""
        {"task":"transcribe","duration":8.0,"text":"...",
         "segments":[
           {"type":"transcript.text.segment","id":"seg_001","start":0.0,"end":1.0,
            "text":"   \\n  ","speaker":"나"},
           {"type":"transcript.text.segment","id":"seg_002","start":1.0,"end":4.7,
            "text":"안녕하세요.","speaker":"A"}],
         "usage":{"type":"duration","seconds":8}}
        """.utf8)
        let client = MockHTTPClient(responseData: payload, statusCode: 200)
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(result.chunks[0].text, "안녕하세요.")
    }

    func test_non_http_response_throws_invalid_response() async {
        let client = NonHTTPResponseClient()
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected invalidResponse to be thrown")
        } catch let error as DiarizedTranscriptionService.ServiceError {
            guard case .invalidResponse = error else {
                XCTFail("Expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected ServiceError.invalidResponse, got \(error)")
        }
    }

    // MARK: - Retry over HTTP status codes

    func test_retries_rate_limit_then_succeeds() async throws {
        let client = MockHTTPClient(stubs: [
            .init(data: Data(#"{"error":{"message":"slow down"}}"#.utf8), statusCode: 429),
            .init(data: Self.successPayload, statusCode: 200)
        ])
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(result.chunks.count, 2)
    }

    func test_does_not_retry_client_error() async {
        let client = MockHTTPClient(stubs: [
            .init(data: Data(#"{"error":{"message":"bad request"}}"#.utf8), statusCode: 400)
        ])
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected a client error to propagate")
        } catch {
            XCTAssertEqual(client.requestCount, 1)
        }
    }

    func test_does_not_sleep_after_the_final_failed_attempt() async {
        // A 2-hour meeting's transcript is at stake; don't make the user wait
        // out a pointless backoff delay after the last attempt has already failed.
        var sleepCount = 0
        let client = MockHTTPClient(
            stubs: [.init(data: Data(#"{"error":{"message":"boom"}}"#.utf8), statusCode: 500)],
            repeatLast: true
        )
        let sut = DiarizedTranscriptionService(
            httpClient: client,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.001),
            sleep: { _ in sleepCount += 1 }
        )

        _ = try? await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(sleepCount, 2)
    }

    func test_gives_up_after_max_attempts() async {
        let client = MockHTTPClient(
            stubs: [.init(data: Data(#"{"error":{"message":"boom"}}"#.utf8), statusCode: 500)],
            repeatLast: true
        )
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected failure after exhausting retries")
        } catch {
            XCTAssertEqual(client.requestCount, 3)
        }
    }

    // MARK: - Retry over thrown transport errors (judgement call)

    func test_retries_transient_network_error_then_succeeds() async throws {
        let client = MockHTTPClient(stubs: [
            .init(error: URLError(.networkConnectionLost)),
            .init(data: Self.successPayload, statusCode: 200)
        ])
        let sut = makeSUT(client: client)

        let result = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)

        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(result.chunks.count, 2)
    }

    func test_gives_up_after_max_attempts_on_persistent_network_error() async {
        let client = MockHTTPClient(
            stubs: [.init(error: URLError(.timedOut))],
            repeatLast: true
        )
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected failure after exhausting retries")
        } catch is URLError {
            XCTAssertEqual(client.requestCount, 3)
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
    }

    func test_does_not_retry_swift_cancellation_error() async {
        let client = MockHTTPClient(stubs: [.init(error: CancellationError())])
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            XCTAssertEqual(client.requestCount, 1)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func test_does_not_retry_url_error_cancelled() async {
        let client = MockHTTPClient(stubs: [.init(error: URLError(.cancelled))])
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected cancellation to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(client.requestCount, 1)
        } catch {
            XCTFail("Expected URLError(.cancelled), got \(error)")
        }
    }

    func test_does_not_retry_non_transient_thrown_error() async {
        let client = MockHTTPClient(stubs: [.init(error: URLError(.badURL))])
        let sut = makeSUT(client: client)

        do {
            _ = try await sut.transcribe(audioURL: audioURL, speakerReference: nil, language: nil)
            XCTFail("Expected error to propagate without retry")
        } catch {
            XCTAssertEqual(client.requestCount, 1)
        }
    }

    func testUploadTooLargeMessageDoesNotPromiseALengthLimit() {
        // It used to name "about 2 hours 20 minutes", derived from the 25 MB
        // upload limit. That was never the binding constraint — the model
        // refuses anything over 1400 seconds long before 25 MB is reached —
        // and segmentation now keeps every request far under both.
        let error = DiarizedTranscriptionService.ServiceError.httpError(413, nil)

        XCTAssertEqual(
            error.errorDescription,
            "The recording was too large to upload. Your audio has been kept, so you can retry."
        )
    }
}

/// Returns a plain (non-HTTP) URLResponse to exercise the guard that rejects it.
private final class NonHTTPResponseClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}
