import Foundation

final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    enum TranscriptionMethod: String, CaseIterable, Identifiable {
        case realtimeWhisper
        case gpt4oTranscribe

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .realtimeWhisper: return "Realtime Whisper"
            case .gpt4oTranscribe: return "GPT-4o Transcribe"
            }
        }

        var model: String {
            switch self {
            case .realtimeWhisper: return ModelSettings.realtimeWhisperModel
            case .gpt4oTranscribe: return ModelSettings.gpt4oTranscribeModel
            }
        }

        var description: String {
            switch self {
            case .realtimeWhisper:
                return "Fast live scribe with partial transcript updates. Higher cost per minute."
            case .gpt4oTranscribe:
                return "Request/response chunk transcription with lower cost and stable final text."
            }
        }
    }

    static let realtimeWhisperModel = "gpt-realtime-whisper"
    static let gpt4oTranscribeModel = "gpt-4o-transcribe"

    static let realtimeTranscriptionModels = [realtimeWhisperModel]
    static let audioTranscriptionModels = [gpt4oTranscribeModel]
    static let transcriptionModels = TranscriptionMethod.allCases.map(\.model)

    static let noteModels = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    // Hard cap on user-supplied instructions appended to the note-generation prompt.
    // Keeps prompt size bounded and limits how far user text can drown out the base contract.
    static let noteInstructionsMaxLength = 2000

    private let defaults: UserDefaults

    @Published var transcriptionMethod: TranscriptionMethod {
        didSet { persistTranscriptionSelection() }
    }

    var transcriptionModel: String {
        get { transcriptionMethod.model }
        set { transcriptionMethod = Self.method(forModel: newValue) }
    }

    @Published var noteModel: String {
        didSet { defaults.set(noteModel, forKey: "noteModel") }
    }

    // BCP-47 language code sent to transcription APIs (e.g. "ko", "en", "ja").
    // Empty string = let the API auto-detect.
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }

    // Optional free-text instructions appended to the note-generation system prompt.
    // Lets users steer tone, structure, or domain focus per their workflow.
    @Published var noteInstructions: String {
        didSet {
            // Clamp to max length so the persisted value can never exceed it,
            // even if a setter wrote a longer string before the UI clamped it.
            if noteInstructions.count > Self.noteInstructionsMaxLength {
                noteInstructions = String(noteInstructions.prefix(Self.noteInstructionsMaxLength))
                return  // didSet re-fires with the clamped value
            }
            defaults.set(noteInstructions, forKey: "noteInstructions")
        }
    }

    /// BCP-47 identifier handed to the on-device transcriber, which — unlike the
    /// API — has no auto-detect mode and needs a concrete locale.
    var effectiveTranscriptionLocaleIdentifier: String {
        transcriptionLanguage.isEmpty ? Locale.current.identifier : transcriptionLanguage
    }

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        transcriptionMethod = Self.savedTranscriptionMethod(in: userDefaults)
        noteModel = userDefaults.string(forKey: "noteModel") ?? "gpt-5.5"
        transcriptionLanguage = userDefaults.string(forKey: "transcriptionLanguage") ?? "ko"
        noteInstructions = userDefaults.string(forKey: "noteInstructions") ?? ""
        persistTranscriptionSelection()
    }

    private func persistTranscriptionSelection() {
        defaults.set(transcriptionMethod.rawValue, forKey: "transcriptionMethod")
        defaults.set(transcriptionMethod.model, forKey: "transcriptionModel")
        defaults.removeObject(forKey: "transcriptionProvider")
    }

    private static func savedTranscriptionMethod(in defaults: UserDefaults) -> TranscriptionMethod {
        if
            let rawMethod = defaults.string(forKey: "transcriptionMethod"),
            let method = TranscriptionMethod(rawValue: rawMethod)
        {
            return method
        }

        let legacyProvider = defaults.string(forKey: "transcriptionProvider")
        let legacyModel = defaults.string(forKey: "transcriptionModel")

        if legacyProvider == "realtimeAPI" || legacyModel == realtimeWhisperModel {
            return .realtimeWhisper
        }
        return .gpt4oTranscribe
    }

    private static func method(forModel model: String) -> TranscriptionMethod {
        model == realtimeWhisperModel ? .realtimeWhisper : .gpt4oTranscribe
    }
}
