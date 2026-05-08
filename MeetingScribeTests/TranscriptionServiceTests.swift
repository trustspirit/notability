import XCTest
@testable import MeetingScribe

final class TranscriptionServiceTests: XCTestCase {
    private let keychainKey = "com.meetingscribe.openai-api-key"

    override func setUp() async throws {
        KeychainHelper.save("sk-test", forKey: keychainKey)
    }

    override func tearDown() async throws {
        KeychainHelper.delete(forKey: keychainKey)
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
}
