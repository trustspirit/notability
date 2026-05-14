import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false
    @State private var keyIsSaved = false
    @ObservedObject private var modelSettings = ModelSettings.shared

    private let keychainKey = "com.meetingscribe.openai-api-key"

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                HStack {
                    if showKey {
                        TextField("sk-...", text: $apiKey)
                    } else {
                        SecureField("sk-...", text: $apiKey)
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                }
                Text("Your key is stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                ModelField(
                    label: "Transcription",
                    value: $modelSettings.transcriptionModel,
                    presets: ModelSettings.transcriptionModels
                )
                ModelField(
                    label: "Note Generation",
                    value: $modelSettings.noteModel,
                    presets: ModelSettings.noteModels
                )
                Text("Model selections are saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") {
                        KeychainHelper.save(apiKey, forKey: keychainKey)
                        keyIsSaved = true
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.isEmpty)

                    if keyIsSaved {
                        Button("Remove Key", role: .destructive) {
                            KeychainHelper.delete(forKey: keychainKey)
                            apiKey = ""
                            keyIsSaved = false
                        }
                    }
                }

                if saved {
                    Label("Saved!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 400)
        .onAppear {
            let stored = KeychainHelper.load(forKey: keychainKey) ?? ""
            apiKey = stored
            keyIsSaved = !stored.isEmpty
        }
    }
}

private struct ModelField: View {
    let label: String
    @Binding var value: String
    let presets: [String]

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("model name", text: $value)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) { value = preset }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a preset")
            }
        }
    }
}
