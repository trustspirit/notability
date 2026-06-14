import XCTest
@testable import Notability

final class TranscriptionServiceTests: XCTestCase {
    private let keychainKey = "com.notability.openai-api-key"
    private var sandbox: CredentialStoreSandbox!
    private var defaultsSuiteNames: [String] = []

    override func setUp() async throws {
        sandbox = CredentialStoreSandbox()
        CredentialsStore.save("sk-test", forKey: keychainKey)
    }

    override func tearDown() async throws {
        CredentialsStore.delete(forKey: keychainKey)
        sandbox.tearDown()
        sandbox = nil
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames = []
    }

    func test_gpt4o_transcribe_method_uses_audio_api_request() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe, language: "ko")
        let mockResponse = "Hello, this is a test transcription."
        let client = MockHTTPClient(responseData: mockResponse.data(using: .utf8)!, statusCode: 200)
        let sut = TranscriptionService(httpClient: client, settings: settings)

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 60.0)

        XCTAssertEqual(chunk.text, "Hello, this is a test transcription.")
        XCTAssertEqual(chunk.timestamp, 60.0)
        XCTAssertEqual(client.requests.first?.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertMultipartBody(client.requests.first?.httpBody, contains: "name=\"model\"\r\n\r\ngpt-4o-transcribe")
    }

    func test_transcribe_throws_on_api_error() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe)
        let client = MockHTTPClient(responseData: Data(), statusCode: 401)
        let sut = TranscriptionService(httpClient: client, settings: settings)

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            _ = try await sut.transcribe(audioURL: tempFile, timestamp: 0)
            XCTFail("Expected error")
        } catch TranscriptionService.APIError.httpError(let code, _) {
            XCTAssertEqual(code, 401)
        }
    }

    func test_realtime_whisper_method_routes_only_to_realtime_engine() async throws {
        let settings = try makeSettings(method: .realtimeWhisper, language: "en")
        let audioEngine = MockTranscriptionEngine(text: "wrong engine")
        let realtimeEngine = MockTranscriptionEngine(text: "Realtime transcript")
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: realtimeEngine,
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 12, prompt: "previous words")

        XCTAssertEqual(chunk.text, "Realtime transcript")
        XCTAssertEqual(audioEngine.calls.count, 0)
        XCTAssertEqual(realtimeEngine.calls.count, 1)
        XCTAssertEqual(realtimeEngine.calls.first?.model, "gpt-realtime-whisper")
        XCTAssertEqual(realtimeEngine.calls.first?.language, "en")
        XCTAssertEqual(realtimeEngine.calls.first?.prompt, "previous words")
    }

    func test_gpt4o_transcribe_method_routes_only_to_audio_engine() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe, language: "ko")
        let audioEngine = MockTranscriptionEngine(text: "GPT-4o transcript")
        let realtimeEngine = MockTranscriptionEngine(text: "wrong engine")
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: realtimeEngine,
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 3)

        XCTAssertEqual(chunk.text, "GPT-4o transcript")
        XCTAssertEqual(audioEngine.calls.count, 1)
        XCTAssertEqual(realtimeEngine.calls.count, 0)
        XCTAssertEqual(audioEngine.calls.first?.model, "gpt-4o-transcribe")
        XCTAssertEqual(audioEngine.calls.first?.language, "ko")
    }

    func test_realtime_whisper_method_forwards_partial_transcripts() async throws {
        let settings = try makeSettings(method: .realtimeWhisper)
        let audioEngine = MockTranscriptionEngine(text: "wrong engine")
        let realtimeEngine = MockTranscriptionEngine(text: "Realtime transcript")
        realtimeEngine.partials = ["실시간", "실시간 자막"]
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: realtimeEngine,
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var partials: [String] = []
        let chunk = try await sut.transcribe(
            audioURL: tempFile,
            timestamp: 3,
            onPartialTranscript: { partials.append($0) }
        )

        XCTAssertEqual(chunk.text, "Realtime transcript")
        XCTAssertEqual(partials, ["실시간", "실시간 자막"])
    }

    func test_language_hint_prompt_is_not_injected_for_gpt4o_transcribe() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe, language: "ko")
        let audioEngine = MockTranscriptionEngine(text: "결과")
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: MockTranscriptionEngine(text: "unused"),
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        _ = try await sut.transcribe(audioURL: tempFile, timestamp: 0)

        XCTAssertNil(audioEngine.calls.first?.prompt)
    }

    func test_explicit_prompt_echo_is_discarded() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe, language: "ko")
        let audioEngine = MockTranscriptionEngine(text: "회의 용어")
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: MockTranscriptionEngine(text: "unused"),
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 0, prompt: "회의 용어")

        XCTAssertEqual(chunk.text, "")
    }

    func test_no_language_when_language_is_not_set() async throws {
        let settings = try makeSettings(method: .gpt4oTranscribe, language: "")
        let audioEngine = MockTranscriptionEngine(text: "result")
        let sut = TranscriptionService(
            audioAPITranscriptionEngine: audioEngine,
            realtimeWhisperTranscriptionEngine: MockTranscriptionEngine(text: "unused"),
            settings: settings
        )

        let tempFile = try makeTempWAV()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        _ = try await sut.transcribe(audioURL: tempFile, timestamp: 0)

        XCTAssertNil(audioEngine.calls.first?.language)
    }

    private func makeSettings(
        method: ModelSettings.TranscriptionMethod,
        language: String = "ko"
    ) throws -> ModelSettings {
        let suiteName = "TranscriptionServiceTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ModelSettings(userDefaults: defaults)
        settings.transcriptionMethod = method
        settings.transcriptionLanguage = language
        return settings
    }

    private func makeTempWAV() throws -> URL {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
        return tempFile
    }

    private func XCTAssertMultipartBody(
        _ data: Data?,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let data, let body = String(data: data, encoding: .utf8) else {
            XCTFail("Missing multipart body", file: file, line: line)
            return
        }
        XCTAssertTrue(body.contains(expected), "Multipart body did not contain \(expected): \(body)", file: file, line: line)
    }
}

private final class MockTranscriptionEngine: TranscriptionEngine {
    struct Call {
        let audioURL: URL
        let apiKey: String
        let model: String
        let language: String?
        let prompt: String?
    }

    let text: String
    var partials: [String] = []
    private(set) var calls: [Call] = []

    init(text: String) {
        self.text = text
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        model: String,
        language: String?,
        prompt: String?,
        onPartialTranscript: TranscriptionPartialHandler?
    ) async throws -> String {
        calls.append(Call(audioURL: audioURL, apiKey: apiKey, model: model, language: language, prompt: prompt))
        for partial in partials {
            await onPartialTranscript?(partial)
        }
        return text
    }
}
