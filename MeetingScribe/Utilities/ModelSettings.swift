import Foundation

final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    static let transcriptionModels = [
        "gpt-4o-transcribe",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe-diarize",
        "whisper-1"
    ]

    static let noteModels = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-4o",
        "gpt-4o-mini"
    ]

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

    private init() {
        transcriptionModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? "gpt-4o-transcribe"
        noteModel = UserDefaults.standard.string(forKey: "noteModel") ?? "gpt-5.5"
        transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "ko"
    }
}
