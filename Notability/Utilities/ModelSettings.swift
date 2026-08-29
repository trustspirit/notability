import Foundation

final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    static let noteModels = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    // Hard cap on user-supplied instructions appended to the note-generation prompt.
    // Keeps prompt size bounded and limits how far user text can drown out the base contract.
    static let noteInstructionsMaxLength = 2000

    /// Written by versions that let the user choose how audio was transcribed.
    /// Nothing reads them now: live captions are on-device and the final pass
    /// always uses the diarization model, so a stored model name could only
    /// misdescribe what the app actually runs.
    private static let legacyTranscriptionKeys = [
        "transcriptionMethod",
        "transcriptionModel",
        "transcriptionProvider"
    ]

    private let defaults: UserDefaults

    @Published var noteModel: String {
        didSet { defaults.set(noteModel, forKey: "noteModel") }
    }

    // BCP-47 language code for both transcription tiers (e.g. "ko", "en", "ja").
    // Empty string = let the diarization API auto-detect; live captions fall back
    // to the system locale, which has no auto-detect mode.
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

    /// Which sources the next recording captures. Set from either place a
    /// recording can be started, so the sidebar toggle and the menu bar always
    /// agree about what the next one will do.
    @Published var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    /// BCP-47 identifier handed to the on-device transcriber, which — unlike the
    /// API — has no auto-detect mode and needs a concrete locale.
    var effectiveTranscriptionLocaleIdentifier: String {
        transcriptionLanguage.isEmpty ? Locale.current.identifier : transcriptionLanguage
    }

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        noteModel = userDefaults.string(forKey: "noteModel") ?? "gpt-5.5"
        transcriptionLanguage = userDefaults.string(forKey: "transcriptionLanguage") ?? "ko"
        noteInstructions = userDefaults.string(forKey: "noteInstructions") ?? ""
        // Falls back to capturing everything rather than to the stored string,
        // because an unrecognised value would otherwise silently record half of
        // every meeting, and no later launch can recover the missing half.
        recordingMode = userDefaults.string(forKey: "recordingMode")
            .flatMap(RecordingMode.init(rawValue:)) ?? .microphoneAndSystem

        // Guarded on presence so this is a one-time cleanup on the first launch
        // after upgrading. `removeObject` takes the write path and posts a change
        // notification whether or not the key exists, so an unguarded loop would
        // pay for the migration on every launch forever.
        for key in Self.legacyTranscriptionKeys where userDefaults.object(forKey: key) != nil {
            userDefaults.removeObject(forKey: key)
        }
    }
}
