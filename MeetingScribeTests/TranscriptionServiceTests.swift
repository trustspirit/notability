import XCTest
@testable import MeetingScribe

final class TranscriptionServiceTests: XCTestCase {
    func test_transcribe_returns_chunk_on_success() async throws {
        let mockResponse = "Hello, this is a test transcription."
        let client = MockHTTPClient(responseData: mockResponse.data(using: .utf8)!, statusCode: 200)
        let sut = TranscriptionService(apiKey: "sk-test", httpClient: client)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.wav")
        try Data().write(to: tempFile)

        let chunk = try await sut.transcribe(audioURL: tempFile, timestamp: 60.0)

        XCTAssertEqual(chunk.text, "Hello, this is a test transcription.")
        XCTAssertEqual(chunk.timestamp, 60.0)
    }

    func test_transcribe_throws_on_api_error() async throws {
        let client = MockHTTPClient(responseData: Data(), statusCode: 401)
        let sut = TranscriptionService(apiKey: "bad-key", httpClient: client)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test2.wav")
        try Data().write(to: tempFile)

        do {
            _ = try await sut.transcribe(audioURL: tempFile, timestamp: 0)
            XCTFail("Expected error")
        } catch TranscriptionService.APIError.httpError(let code) {
            XCTAssertEqual(code, 401)
        }
    }
}
