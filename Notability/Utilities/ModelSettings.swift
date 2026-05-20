import Foundation

final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    enum TranscriptionProvider: String, CaseIterable, Identifiable {
        case audioAPI
        case realtimeAPI

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .audioAPI: return "Audio API"
            case .realtimeAPI: return "Realtime API"
            }
        }

        var defaultModel: String {
            switch self {
            case .audioAPI: return "gpt-4o-transcribe"
            case .realtimeAPI: return "gpt-realtime-whisper"
            }
        }

        var models: [String] {
            switch self {
            case .audioAPI: return ModelSettings.audioTranscriptionModels
            case .realtimeAPI: return ModelSettings.realtimeTranscriptionModels
            }
        }
    }

    static let audioTranscriptionModels = [
        "gpt-4o-transcribe",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe-diarize",
        "whisper-1"
    ]

    static let realtimeTranscriptionModels = [
        "gpt-realtime-whisper"
    ]

    static let transcriptionModels = audioTranscriptionModels + realtimeTranscriptionModels

    static let noteModels = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    // Hard cap on user-supplied instructions appended to the note-generation prompt.
    // Keeps prompt size bounded and limits how far user text can drown out the base contract.
    static let noteInstructionsMaxLength = 2000

    @Published var transcriptionProvider: TranscriptionProvider {
        didSet {
            UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider")
            if !transcriptionProvider.models.contains(transcriptionModel) {
                transcriptionModel = transcriptionProvider.defaultModel
            }
        }
    }

    @Published var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "transcriptionModel") }
    }

    @Published var noteModel: String {
        didSet { UserDefaults.standard.set(noteModel, forKey: "noteModel") }
    }

    // BCP-47 language code sent to Whisper (e.g. "ko", "en", "ja").
    // Empty string = let Whisper auto-detect, but auto-detect can misfire on short clips.
    @Published var transcriptionLanguage: String {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
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
            UserDefaults.standard.set(noteInstructions, forKey: "noteInstructions")
        }
    }

    private init() {
        let providerRaw = UserDefaults.standard.string(forKey: "transcriptionProvider")
        let savedProvider = TranscriptionProvider(rawValue: providerRaw ?? "") ?? .audioAPI
        let savedTranscriptionModel = UserDefaults.standard.string(forKey: "transcriptionModel")

        if let savedTranscriptionModel, savedProvider.models.contains(savedTranscriptionModel) {
            transcriptionProvider = savedProvider
            transcriptionModel = savedTranscriptionModel
        } else if let savedTranscriptionModel, Self.realtimeTranscriptionModels.contains(savedTranscriptionModel) {
            transcriptionProvider = .realtimeAPI
            transcriptionModel = savedTranscriptionModel
        } else {
            transcriptionProvider = savedProvider
            transcriptionModel = savedProvider.defaultModel
        }

        noteModel = UserDefaults.standard.string(forKey: "noteModel") ?? "gpt-5.5"
        transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "ko"
        noteInstructions = UserDefaults.standard.string(forKey: "noteInstructions") ?? ""
    }
}
