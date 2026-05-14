import Foundation

final class TranscriptionService: TranscriptionServiceProtocol {
    enum APIError: Error, LocalizedError {
        case httpError(Int)
        case invalidResponse
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is not set. Go to Settings and enter your API key."
            case .httpError(let code):
                return "OpenAI API returned HTTP \(code). Check your API key and quota."
            case .invalidResponse:
                return "Received an unexpected response from OpenAI."
            }
        }
    }

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func transcribe(audioURL: URL, timestamp: TimeInterval) async throws -> TranscriptChunk {
        guard let apiKey = KeychainHelper.load(forKey: "com.meetingscribe.openai-api-key"), !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }
        let model = ModelSettings.shared.transcriptionModel

        let audioData = try Data(contentsOf: audioURL)
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(audioData: audioData, filename: audioURL.lastPathComponent, boundary: boundary, model: model)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }

        let text = String(data: data, encoding: .utf8) ?? ""
        return TranscriptChunk(timestamp: timestamp, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func buildMultipartBody(audioData: Data, filename: String, boundary: String, model: String) -> Data {
        var body = Data()
        let CRLF = "\r\n"
        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(CRLF)\(CRLF)\(model)\(CRLF)".data(using: .utf8)!)
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
