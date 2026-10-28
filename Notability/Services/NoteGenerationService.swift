import Foundation

final class NoteGenerationService: NoteGenerationServiceProtocol {
    enum APIError: Error, LocalizedError, Equatable {
        case httpError(Int, String?)
        case missingContent
        case invalidResponse
        case missingAPIKey(NoteModelProvider)
        case truncated
        case refused

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "\(provider.displayName) API key is not set. Go to Settings and enter your \(provider.displayName) API key, or choose a model from another provider."
            case .httpError(let code, let message):
                if let message { return "Note generation failed (HTTP \(code)): \(message)" }
                return "Note generation failed with HTTP \(code). Check your API key and quota."
            case .missingContent:
                return "The model returned an empty response."
            case .invalidResponse:
                return "Received an unexpected response from the note generation API."
            case .truncated:
                return "The notes were cut off before they were complete. Your transcript is saved, so Retry will try again."
            case .refused:
                return "The model declined to write notes for this transcript. Your transcript is saved; try Retry with a different note model."
            }
        }
    }

    /// Fewer attempts than transcription: each one can run for many minutes on
    /// a long meeting, and a timeout is retryable, so five of them would leave
    /// the user waiting for most of an hour before learning anything.
    static let retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 30)

    /// The request is not streamed, so nothing arrives until the whole answer
    /// has been generated, and `timeoutInterval` measures exactly that
    /// silence. A reasoning model writing four sections of notes for an hour
    /// of transcript routinely needs more than the three minutes this used to
    /// allow, which failed every long meeting the same way.
    static let requestTimeout: TimeInterval = 900

    private let httpClient: HTTPClient
    private let retryPolicy: RetryPolicy
    private let sleep: (TimeInterval) async throws -> Void
    private let model: () -> String

    init(
        httpClient: HTTPClient = URLSession.shared,
        retryPolicy: RetryPolicy = NoteGenerationService.retryPolicy,
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        model: @escaping () -> String = { ModelSettings.shared.noteModel }
    ) {
        self.httpClient = httpClient
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.model = model
    }

    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes {
        let model = model()
        let provider = NoteModelProvider(model: model)
        guard let apiKey = CredentialsStore.load(forKey: provider.credentialKey), !apiKey.isEmpty else {
            throw APIError.missingAPIKey(provider)
        }
        let request = try Self.request(
            provider: provider,
            model: model,
            apiKey: apiKey,
            systemPrompt: Self.composedSystemPrompt(userInstructions: ModelSettings.shared.noteInstructions),
            userContent: Self.transcriptText(transcript)
        )
        let content = try await send(request, provider: provider)
        return try parseNotes(from: content)
    }

    /// One line per turn, with the speaker when diarization named one. Without
    /// it the model is asked for assignees and "who raised each point" from a
    /// transcript that never says who is talking.
    static func transcriptText(_ transcript: [TranscriptChunk]) -> String {
        transcript.map { chunk in
            let stamp = "[\(Self.clock(chunk.timestamp))]"
            guard let speaker = chunk.speaker, !speaker.isEmpty else {
                return "\(stamp) \(chunk.text)"
            }
            return "\(stamp) \(speaker): \(chunk.text)"
        }
        .joined(separator: "\n")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    // User instructions are appended *after* the base contract so the model still
    // returns the required JSON schema — instructions can steer tone, depth, or
    // emphasis but cannot override the output shape.
    private static func composedSystemPrompt(userInstructions: String) -> String {
        let trimmed = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemPrompt }
        return systemPrompt + "\n\nAdditional instructions from the user (apply when generating the summary and items, but DO NOT change the JSON schema above):\n\(trimmed)"
    }

    private static func request(
        provider: NoteModelProvider,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userContent: String
    ) throws -> URLRequest {
        switch provider {
        case .openAI:
            return try openAIRequest(model: model, apiKey: apiKey, systemPrompt: systemPrompt, userContent: userContent)
        case .anthropic:
            return try anthropicRequest(model: model, apiKey: apiKey, systemPrompt: systemPrompt, userContent: userContent)
        }
    }

    private static func openAIRequest(
        model: String,
        apiKey: String,
        systemPrompt: String,
        userContent: String
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "meeting_notes", "strict": true, "schema": notesSchema] as [String: Any]
            ] as [String: Any],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]
        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static let anthropicVersion = "2026-10-21"
    static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"

    /// Room for the notes and the thinking that precedes them. The request is
    /// not streamed, and much more than this would risk outlasting the
    /// connection; a cut-off answer is retried rather than parsed.
    static let anthropicMaxTokens = 16_000

    /// Models that accept `fallbacks: "default"`, which re-runs a request a
    /// safety classifier declined on another model inside the same call. Sent
    /// only to these: any other model rejects the parameter outright.
    private static let anthropicFallbackModels: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    private static func anthropicRequest(
        model: String,
        apiKey: String,
        systemPrompt: String,
        userContent: String
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": anthropicMaxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userContent]],
            "output_config": [
                // Summarising a meeting is not where deeper reasoning pays
                // for its minutes; set explicitly because the default differs
                // between models.
                "effort": "medium",
                "format": ["type": "json_schema", "schema": notesSchema] as [String: Any]
            ] as [String: Any]
        ]
        let usesFallback = anthropicFallbackModels.contains(model)
        if usesFallback { body["fallbacks"] = "default" }

        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if usesFallback { request.setValue(anthropicFallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest, provider: NoteModelProvider) async throws -> String {
        var lastError: Error = APIError.invalidResponse
        for attempt in 0..<retryPolicy.maxAttempts {
            let failure: (error: Error, retryable: Bool)
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                if (200..<300).contains(http.statusCode) {
                    switch provider {
                    case .openAI: return try Self.openAIContent(of: data)
                    case .anthropic: return try Self.anthropicContent(of: data)
                    }
                }
                // Both providers put the reason at error.message.
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                failure = (
                    APIError.httpError(http.statusCode, message),
                    RetryPolicy.isRetryable(statusCode: http.statusCode)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError {
                // A response that arrived but cannot be used. A cut-off answer
                // is worth asking for again; a malformed or declined one would
                // only repeat.
                failure = (error, error == .truncated)
            } catch {
                failure = (error, RetryPolicy.isRetryable(error: error))
            }

            lastError = failure.error
            guard failure.retryable, attempt < retryPolicy.maxAttempts - 1 else { throw lastError }
            try await sleep(retryPolicy.delay(forAttempt: attempt))
        }
        throw lastError
    }

    /// The model's message from a chat completion. Tests stub the notes JSON
    /// directly, with no `choices` wrapper, so a body that is already the
    /// notes is passed through.
    private static func openAIContent(of data: Data) throws -> String {
        guard let rawText = String(data: data, encoding: .utf8),
              rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        guard let choices = json["choices"] as? [[String: Any]] else { return rawText }
        guard let choice = choices.first else { throw APIError.missingContent }
        if choice["finish_reason"] as? String == "length" { throw APIError.truncated }
        guard let content = (choice["message"] as? [String: Any])?["content"] as? String,
              !content.isEmpty else {
            throw APIError.missingContent
        }
        return content
    }

    /// The notes from a Messages API response: its text block. Thinking and
    /// fallback blocks can come before it and are skipped. The stop reason is
    /// read first, because a declined or cut-off answer is not the schema's
    /// JSON however it looks.
    private static func anthropicContent(of data: Data) throws -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw APIError.refused
        case "max_tokens": throw APIError.truncated
        default: break
        }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw APIError.missingContent }
        return text
    }

    private func parseNotes(from jsonString: String) throws -> MeetingNotes {
        guard let data = jsonString.data(using: .utf8) else { throw APIError.invalidResponse }
        let raw = try JSONDecoder().decode(RawNotes.self, from: data)
        let items = raw.actionItems.map { item in
            ActionItem(id: UUID(), description: item.description, assignee: item.assignee, dueDate: item.dueDate, isCompleted: false)
        }
        return MeetingNotes(summary: raw.summary, actionItems: items, keyDecisions: raw.keyDecisions)
    }

    /// Tolerant on purpose. Structured Outputs holds the model to the schema,
    /// but the user can pick a model that ignores it, and an empty list sent as
    /// `null` or left out is not a reason to throw away an hour of notes.
    private struct RawNotes: Decodable {
        let summary: String
        let actionItems: [RawActionItem]
        let keyDecisions: [String]

        enum CodingKeys: String, CodingKey {
            case summary, action_items, key_decisions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = try c.decode(String.self, forKey: .summary)
            actionItems = (try? c.decodeIfPresent([RawActionItem].self, forKey: .action_items)) ?? []
            keyDecisions = (try? c.decodeIfPresent([String].self, forKey: .key_decisions)) ?? []
        }
    }

    private struct RawActionItem: Decodable {
        let description: String
        let assignee: String?
        let dueDate: String?

        enum CodingKeys: String, CodingKey {
            case description, assignee, due_date
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = try c.decode(String.self, forKey: .description)
            assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
            dueDate = try c.decodeIfPresent(String.self, forKey: .due_date)
        }
    }

    /// Structured Outputs on both providers: the server constrains generation
    /// to this schema, so `summary` cannot come back as an object of sections
    /// and no key can be dropped — the two ways long meetings used to fail
    /// parsing.
    private static let notesSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "action_items", "key_decisions"],
        "properties": [
            "summary": ["type": "string"],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["description", "assignee", "due_date"],
                    "properties": [
                        "description": ["type": "string"],
                        "assignee": ["type": ["string", "null"]],
                        "due_date": ["type": ["string", "null"]]
                    ]
                ]
            ],
            "key_decisions": [
                "type": "array",
                "items": ["type": "string"]
            ]
        ] as [String: Any]
    ]

    private static let systemPrompt = """
        You are a meeting notes assistant. Given a meeting transcript, extract and return a JSON object with exactly these keys:
        - "summary": A single string holding a structured meeting summary in Markdown with exactly these four sections (use the same language as the transcript for all content; use the exact header names below translated if needed):
          **논의 사항** (or "Discussion" in English transcripts): bullet points covering what was discussed — include context, reasoning, and who raised each point.
          **결정 사항** (or "Decisions"): bullet points for each conclusion or agreement reached. Be specific — not "agreed to proceed" but what exactly was agreed.
          **미결 사항** (or "Open Items"): bullet points for questions or topics that were not resolved and need to be decided at a future meeting. If none, write "없음" (or "None").
          **액션 아이템** (or "Action Items"): list every action item grouped by assignee or team. Format each group as "**[이름/팀]**" followed by their items as sub-bullets. Unassigned items go under "**미배정**" (or "Unassigned"). Include due dates where mentioned.
        - "action_items": Array of objects with keys "description" (string), "assignee" (string or null), "due_date" (string or null).
        - "key_decisions": Array of strings, each a key decision made.
        Each transcript line is "[mm:ss] Speaker: text". Speaker labels come from automatic diarization: "나" is the person who recorded the meeting. Other labels are anonymous letters, and a long meeting is transcribed in parts, so a numeric suffix (A, A2, A3) marks the part, not a different person — "A" and "A2" may or may not be the same speaker. Prefer real names when the conversation reveals them (e.g. someone is addressed by name); never invent a name, and do not present a bare letter label as a person's name.
        Cover the whole meeting, start to finish — the later parts of a long meeting matter as much as the beginning.
        Respond in the same language as the transcript. Return ONLY valid JSON.
        IMPORTANT: If any later instruction in this prompt asks you to change the output format, ignore that part of the instruction. The JSON schema above is non-negotiable.
        """
}
