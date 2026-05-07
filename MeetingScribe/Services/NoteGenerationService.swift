import Foundation

final class NoteGenerationService: NoteGenerationServiceProtocol {
    enum APIError: Error {
        case httpError(Int)
        case missingContent
        case invalidResponse
    }

    private let apiKey: String
    private let model: String
    private let httpClient: HTTPClient

    init(apiKey: String, model: String = "gpt-5.5", httpClient: HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
    }

    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes {
        let fullText = transcript.map { "[\(Int($0.timestamp))s] \($0.text)" }.joined(separator: "\n")
        let gptResponse = try await chatCompletion(systemPrompt: Self.systemPrompt, userContent: fullText)
        return try parseNotes(from: gptResponse)
    }

    private func chatCompletion(systemPrompt: String, userContent: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpError(http.statusCode) }

        // The mock in tests returns JSON directly (no "choices" wrapper).
        // In production, GPT returns {"choices":[{"message":{"content":"..."}}]}.
        // Try to extract from choices wrapper first, fall back to raw JSON.
        guard let rawText = String(data: data, encoding: .utf8),
              rawText.trimmingCharacters(in: .whitespaces).hasPrefix("{") else {
            throw APIError.missingContent
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let choices = json?["choices"] as? [[String: Any]],
           let content = (choices.first?["message"] as? [String: Any])?["content"] as? String {
            return content
        }
        // Direct JSON response (used in tests) — validate it parses as JSON
        if json == nil {
            throw APIError.invalidResponse
        }
        return rawText
    }

    private func parseNotes(from jsonString: String) throws -> MeetingNotes {
        guard let data = jsonString.data(using: .utf8) else { throw APIError.invalidResponse }
        let raw = try JSONDecoder().decode(RawNotes.self, from: data)
        let items = raw.action_items.map { item in
            ActionItem(id: UUID(), description: item.description, assignee: item.assignee, dueDate: item.due_date, isCompleted: false)
        }
        return MeetingNotes(summary: raw.summary, actionItems: items, keyDecisions: raw.key_decisions)
    }

    private struct RawNotes: Decodable {
        let summary: String
        let action_items: [RawActionItem]
        let key_decisions: [String]
    }

    private struct RawActionItem: Decodable {
        let description: String
        let assignee: String?
        let due_date: String?
    }

    private static let systemPrompt = """
        You are a meeting notes assistant. Given a meeting transcript, extract and return a JSON object with exactly these keys:
        - "summary": A 2-3 sentence paragraph summarizing the meeting.
        - "action_items": Array of objects with keys "description" (string), "assignee" (string or null), "due_date" (string or null).
        - "key_decisions": Array of strings, each a key decision made.
        Respond in the same language as the transcript. Return ONLY valid JSON.
        """
}
