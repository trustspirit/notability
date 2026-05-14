import AVFoundation
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

    private let audioAPITranscriber: any OpenAITranscriber
    private let realtimeAPITranscriber: any OpenAITranscriber
    private let settings: ModelSettings

    init(
        httpClient: HTTPClient = URLSession.shared,
        settings: ModelSettings = .shared
    ) {
        self.audioAPITranscriber = AudioAPITranscriber(httpClient: httpClient)
        self.realtimeAPITranscriber = RealtimeAPITranscriber()
        self.settings = settings
    }

    init(
        audioAPITranscriber: any OpenAITranscriber,
        realtimeAPITranscriber: any OpenAITranscriber,
        settings: ModelSettings = .shared
    ) {
        self.audioAPITranscriber = audioAPITranscriber
        self.realtimeAPITranscriber = realtimeAPITranscriber
        self.settings = settings
    }

    func transcribe(audioURL: URL, timestamp: TimeInterval, prompt: String? = nil) async throws -> TranscriptChunk {
        guard let apiKey = KeychainHelper.load(forKey: "com.meetingscribe.openai-api-key"), !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }

        let model = settings.transcriptionModel
        let language = settings.transcriptionLanguage.isEmpty ? nil : settings.transcriptionLanguage
        let transcriber = selectedTranscriber(for: model)
        let text = try await transcriber.transcribe(
            audioURL: audioURL,
            apiKey: apiKey,
            model: model,
            language: language,
            prompt: prompt
        )

        return TranscriptChunk(timestamp: timestamp, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func selectedTranscriber(for model: String) -> any OpenAITranscriber {
        if settings.transcriptionProvider == .realtimeAPI || ModelSettings.realtimeTranscriptionModels.contains(model) {
            return realtimeAPITranscriber
        }
        return audioAPITranscriber
    }
}

protocol OpenAITranscriber {
    func transcribe(audioURL: URL, apiKey: String, model: String, language: String?, prompt: String?) async throws -> String
}

final class AudioAPITranscriber: OpenAITranscriber {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func transcribe(audioURL: URL, apiKey: String, model: String, language: String?, prompt: String?) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            boundary: boundary,
            model: model,
            language: language,
            prompt: prompt
        )

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionService.APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TranscriptionService.APIError.httpError(http.statusCode) }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func buildMultipartBody(
        audioData: Data,
        filename: String,
        boundary: String,
        model: String,
        language: String?,
        prompt: String?
    ) -> Data {
        var body = Data()
        let CRLF = "\r\n"

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(CRLF)\(CRLF)\(value)\(CRLF)".data(using: .utf8)!)
        }

        field("model", model)
        field("response_format", "text")
        if let language { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }

        body.append("--\(boundary)\(CRLF)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(CRLF)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(CRLF)\(CRLF)".data(using: .utf8)!)
        body.append(audioData)
        body.append("\(CRLF)--\(boundary)--\(CRLF)".data(using: .utf8)!)
        return body
    }
}

final class RealtimeAPITranscriber: OpenAITranscriber {
    private let session: URLSession
    private let inputSampleRate = 24_000
    private let sendChunkByteCount = 24_000
    private let responseTimeoutNanoseconds: UInt64 = 60_000_000_000

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(audioURL: URL, apiKey: String, model: String, language: String?, prompt: String?) async throws -> String {
        let pcmData = try convertToRealtimePCM16(audioURL: audioURL)
        guard !pcmData.isEmpty else { return "" }

        var request = URLRequest(url: endpoint(for: model))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await sendSessionUpdate(to: task, model: model, language: language)
        try await sendAudio(pcmData, to: task)
        try await sendJSON(["type": "input_audio_buffer.commit"], to: task)

        return try await receiveTranscript(from: task)
    }

    private func endpoint(for model: String) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    private func sendSessionUpdate(
        to task: URLSessionWebSocketTask,
        model: String,
        language: String?
    ) async throws {
        var transcription: [String: Any] = ["model": model]
        if let language { transcription["language"] = language }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": inputSampleRate
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ], to: task)
    }

    private func sendAudio(_ pcmData: Data, to task: URLSessionWebSocketTask) async throws {
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + sendChunkByteCount, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ], to: task)
            offset = end
        }
    }

    private func receiveTranscript(from task: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.waitForCompletedTranscript(from: task) }
            group.addTask {
                try await Task.sleep(nanoseconds: self.responseTimeoutNanoseconds)
                throw RealtimeTranscriptionError.timeout
            }

            guard let result = try await group.next() else {
                throw RealtimeTranscriptionError.closedWithoutTranscript
            }
            group.cancelAll()
            return result
        }
    }

    private func waitForCompletedTranscript(from task: URLSessionWebSocketTask) async throws -> String {
        var deltaFallback = ""

        while true {
            let message = try await task.receive()
            let data: Data

            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let messageData):
                data = messageData
            @unknown default:
                continue
            }

            guard
                let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else {
                continue
            }

            switch type {
            case "conversation.item.input_audio_transcription.delta":
                deltaFallback += event["delta"] as? String ?? ""
            case "conversation.item.input_audio_transcription.completed":
                return event["transcript"] as? String ?? deltaFallback
            case "error":
                let error = event["error"] as? [String: Any]
                let message = error?["message"] as? String ?? event["message"] as? String ?? "Realtime transcription failed."
                throw RealtimeTranscriptionError.server(message)
            default:
                continue
            }
        }
    }

    private func sendJSON(_ object: [String: Any], to task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionService.APIError.invalidResponse
        }
        try await task.send(.string(text))
    }

    private func convertToRealtimePCM16(audioURL: URL) throws -> Data {
        let file = try AVAudioFile(forReading: audioURL)
        let inputFormat = file.processingFormat
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        try file.read(into: inputBuffer)
        guard inputBuffer.frameLength > 0 else { return Data() }

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(inputSampleRate),
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        let frameRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * frameRatio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        if conversionError != nil {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard byteCount > 0, let bytes = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }
}

private enum RealtimeTranscriptionError: Error, LocalizedError {
    case audioConversionFailed
    case closedWithoutTranscript
    case server(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .audioConversionFailed:
            return "Could not convert audio into the PCM format required by Realtime transcription."
        case .closedWithoutTranscript:
            return "Realtime transcription finished without returning a transcript."
        case .server(let message):
            return message
        case .timeout:
            return "Realtime transcription timed out."
        }
    }
}
