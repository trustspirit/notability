import XCTest
@testable import MeetingScribe

final class TranscriptionServiceTests: XCTestCase {
    private let keychainKey = "com.meetingscribe.openai-api-key"

    override func setUp() async throws {
        KeychainHelper.save("sk-test", forKey: keychainKey)
        ModelSettings.shared.transcriptionProvider = .audioAPI
        ModelSettings.shared.transcriptionModel = "gpt-4o-transcribe"
        ModelSettings.shared.transcriptionLanguage = "ko"
    }

    override func tearDown() async throws {
        KeychainHelper.delete(forKey: keychainKey)
        ModelSettings.shared.transcriptionProvider = .audioAPI
        ModelSettings.shared.transcriptionModel = "gpt-4o-transcribe"
        ModelSettings.shared.transcriptionLanguage = "ko"
    }

    func test_transcribe_returns_chunk_on_success() async throws {
        let mockResponse = "Hello, this is a test transcription."
        let client = MockHTTPClient(responseData: mockResponse.data(using: .utf8)!, statusCode: 200)
        let sut = TranscriptionService(httpClient: client)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
        // service deletes the file on success — defer handles unexpected early exit
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 60.0)

        XCTAssertEqual(chunk.text, "Hello, this is a test transcription.")
        XCTAssertEqual(chunk.timestamp, 60.0)
        XCTAssertEqual(client.requests.first?.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(client.requests.count, 1)
    }

    func test_transcribe_throws_on_api_error() async throws {
        let client = MockHTTPClient(responseData: Data(), statusCode: 401)
        let sut = TranscriptionService(httpClient: client)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            _ = try await sut.transcribe(audioURL: tempFile, timestamp: 0)
            XCTFail("Expected error")
        } catch TranscriptionService.APIError.httpError(let code) {
            XCTAssertEqual(code, 401)
        }
    }

    func test_realtime_provider_routes_to_realtime_transcriber() async throws {
        ModelSettings.shared.transcriptionProvider = .realtimeAPI
        ModelSettings.shared.transcriptionModel = "gpt-realtime-whisper"
        ModelSettings.shared.transcriptionLanguage = "en"

        let audioAPI = MockTranscriber(text: "wrong provider")
        let realtimeAPI = MockTranscriber(text: "Realtime transcript")
        let sut = TranscriptionService(audioAPITranscriber: audioAPI, realtimeAPITranscriber: realtimeAPI)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 12, prompt: "previous words")

        XCTAssertEqual(chunk.text, "Realtime transcript")
        XCTAssertEqual(audioAPI.calls.count, 0)
        XCTAssertEqual(realtimeAPI.calls.count, 1)
        XCTAssertEqual(realtimeAPI.calls.first?.model, "gpt-realtime-whisper")
        XCTAssertEqual(realtimeAPI.calls.first?.language, "en")
        XCTAssertEqual(realtimeAPI.calls.first?.prompt, "previous words")
    }

    func test_realtime_provider_forwards_partial_transcripts() async throws {
        ModelSettings.shared.transcriptionProvider = .realtimeAPI
        ModelSettings.shared.transcriptionModel = "gpt-realtime-whisper"

        let audioAPI = MockTranscriber(text: "wrong provider")
        let realtimeAPI = MockTranscriber(text: "Realtime transcript")
        realtimeAPI.partials = ["실시간", "실시간 자막"]
        let sut = TranscriptionService(audioAPITranscriber: audioAPI, realtimeAPITranscriber: realtimeAPI)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
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

    func test_realtime_model_routes_to_realtime_transcriber_even_when_provider_is_audio_api() async throws {
        ModelSettings.shared.transcriptionProvider = .audioAPI
        ModelSettings.shared.transcriptionModel = "gpt-realtime-whisper"

        let audioAPI = MockTranscriber(text: "wrong provider")
        let realtimeAPI = MockTranscriber(text: "Realtime transcript")
        let sut = TranscriptionService(audioAPITranscriber: audioAPI, realtimeAPITranscriber: realtimeAPI)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 3)

        XCTAssertEqual(chunk.text, "Realtime transcript")
        XCTAssertEqual(audioAPI.calls.count, 0)
        XCTAssertEqual(realtimeAPI.calls.count, 1)
    }
}

private final class MockTranscriber: OpenAITranscriber {
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
