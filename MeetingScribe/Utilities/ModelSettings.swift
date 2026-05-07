import Foundation

final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    static let transcriptionModels = [
        "gpt-4o-transcribe",
        "gpt-4o-mini-transcribe",
        "whisper-1"
    ]

    static let noteModels = [
        "gpt-5.5",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    @Published var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "transcriptionModel") }
    }

    @Published var noteModel: String {
        didSet { UserDefaults.standard.set(noteModel, forKey: "noteModel") }
    }

    private init() {
        transcriptionModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? "gpt-4o-transcribe"
        noteModel = UserDefaults.standard.string(forKey: "noteModel") ?? "gpt-5.5"
    }
}
