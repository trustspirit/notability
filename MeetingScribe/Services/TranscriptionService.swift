import Foundation

final class TranscriptionService: TranscriptionServiceProtocol {
    enum APIError: Error {
        case httpError(Int)
        case invalidResponse
    }

    private let apiKey: String
    private let httpClient: HTTPClient

    init(apiKey: String, httpClient: HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    func transcribe(audioURL: URL, timestamp: TimeInterval) async throws -> TranscriptChunk {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(audioData: audioData, filename: audioURL.lastPathComponent, boundary: boundary)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }

        let text = String(data: data, encoding: .utf8) ?? ""
        try? FileManager.default.removeItem(at: audioURL)  // clean up temp WAV file
        return TranscriptChunk(timestamp: timestamp, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func buildMultipartBody(audioData: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        let CRLF = "\r\n"
        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(CRLF)\(CRLF)gpt-4o-transcribe\(CRLF)".data(using: .utf8)!)
        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(CRLF)\(CRLF)text\(CRLF)".data(using: .utf8)!)
        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(CRLF)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(CRLF)\(CRLF)".data(using: .utf8)!)
        body.append(audioData)
        body.append("\(CRLF)--\(boundary)--\(CRLF)".data(using: .utf8)!)
        return body
    }
}
