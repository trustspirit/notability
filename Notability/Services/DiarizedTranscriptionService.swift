import Foundation

/// Transcribes the full mixed session recording in one request. Seeing the whole
/// meeting at once is what makes punctuation, terminology, and speaker
/// separation consistent — none of which is possible when audio is cut into
/// multi-second fragments and transcribed independently.
final class DiarizedTranscriptionService: FinalTranscriptionServiceProtocol {
    enum ServiceError: Error, LocalizedError {
        case missingAPIKey
        case invalidResponse
        case httpError(Int, String?)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is not set. Go to Settings and enter your API key."
            case .invalidResponse:
                return "Received an unexpected response from the transcription API."
            case .httpError(let code, let detail):
                switch code {
                case 401: return "Invalid OpenAI API key (HTTP 401). Go to Settings and verify your key."
                case 413: return "The recording was too large to upload. Your audio has been kept, so you can retry."
                case 429: return "OpenAI rate limit or quota exceeded (HTTP 429)."
                default:  return "Transcription failed with HTTP \(code)\(detail.map { ": \($0)" } ?? "")."
                }
            }
        }
    }

    static let model = "gpt-4o-transcribe-diarize"
    static let localSpeakerName = "나"

    private let httpClient: HTTPClient
    private let retryPolicy: RetryPolicy
    private let sleep: (TimeInterval) async throws -> Void

    init(
        httpClient: HTTPClient = URLSession.shared,
        retryPolicy: RetryPolicy = .standard,
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.httpClient = httpClient
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    func transcribe(
        audioURL: URL,
        speakerReference: Data?,
        language: String?
    ) async throws -> DiarizedTranscription {
        guard let apiKey = CredentialsStore.load(forKey: "com.notability.openai-api-key"),
              !apiKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }
        let audioData = try Data(contentsOf: audioURL)

        var lastError: Error = ServiceError.invalidResponse
        for attempt in 0..<retryPolicy.maxAttempts {
            let request = buildRequest(
                apiKey: apiKey,
                audioData: audioData,
                filename: audioURL.lastPathComponent,
                speakerReference: speakerReference,
                language: language
            )

            let failure: (error: Error, retryable: Bool)
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) {
                    return try Self.parse(data)
                }
                let detail = Self.errorMessage(from: data)
                failure = (
                    ServiceError.httpError(http.statusCode, detail),
                    RetryPolicy.isRetryable(statusCode: http.statusCode)
                )
            } catch is CancellationError {
                // The caller stopped waiting; redoing the request would be a bug.
                throw CancellationError()
            } catch {
                failure = (error, RetryPolicy.isRetryable(error: error))
            }

            lastError = failure.error
            let isLastAttempt = attempt == retryPolicy.maxAttempts - 1
            guard failure.retryable, !isLastAttempt else {
                throw lastError
            }
            try await sleep(retryPolicy.delay(forAttempt: attempt))
        }
        throw lastError
    }

    private func buildRequest(
        apiKey: String,
        audioData: Data,
        filename: String,
        speakerReference: Data?,
        language: String?
    ) -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            timeoutInterval: 600
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let CRLF = "\r\n"

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(CRLF)\(CRLF)\(value)\(CRLF)".data(using: .utf8)!)
        }

        field("model", Self.model)
        field("response_format", "diarized_json")
        // Required for recordings longer than 30 seconds.
        field("chunking_strategy", "auto")
        if let language, !language.isEmpty { field("language", language) }
        if let speakerReference {
            field("known_speaker_names[]", Self.localSpeakerName)
            field(
                "known_speaker_references[]",
                "data:audio/wav;base64,\(speakerReference.base64EncodedString())"
            )
        }

        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(CRLF)".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\(CRLF)\(CRLF)".data(using: .utf8)!)
        body.append(audioData)
        body.append("\(CRLF)--\(boundary)--\(CRLF)".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    private static func parse(_ data: Data) throws -> DiarizedTranscription {
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        let chunks = decoded.segments
            .map { segment in
                TranscriptChunk(
                    timestamp: segment.start,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: segment.speaker
                )
            }
            .filter { !$0.text.isEmpty }
        return DiarizedTranscription(chunks: chunks, billedSeconds: decoded.usage?.seconds)
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["message"] as? String }
    }

    private struct Payload: Decodable {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: String?
        }
        struct Usage: Decodable {
            let seconds: Int?
        }
        let segments: [Segment]
        let usage: Usage?
    }
}
