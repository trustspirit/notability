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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                apiKeySection
                modelsSection
                noteInstructionsSection
            }
            .padding(Spacing.xl)
        }
        .frame(width: 520, height: 640)
        .background(BrandColor.surfaceElevated)
        .onAppear {
            let stored = KeychainHelper.load(forKey: keychainKey) ?? ""
            apiKey = stored
            keyIsSaved = !stored.isEmpty
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(text: "OpenAI API Key")
            Card {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Group {
                            if showKey {
                                TextField("sk-…", text: $apiKey)
                            } else {
                                SecureField("sk-…", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.bordered)
                        .help(showKey ? "Hide key" : "Show key")
                    }

                    HStack(spacing: Spacing.sm) {
                        Button {
                            KeychainHelper.save(apiKey, forKey: keychainKey)
                            keyIsSaved = true
                            saved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                        } label: {
                            Label("Save Key", systemImage: "lock.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.isEmpty)

                        if keyIsSaved {
                            Button(role: .destructive) {
                                KeychainHelper.delete(forKey: keychainKey)
                                apiKey = ""
                                keyIsSaved = false
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(BrandColor.success)
                                .font(.callout.weight(.medium))
                        }
                        Spacer()
                    }

                    Text("Your key is stored securely in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(text: "Models")
            Card {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Transcription method")
                            .font(.callout.weight(.medium))
                        Picker("", selection: $modelSettings.transcriptionProvider) {
                            ForEach(ModelSettings.TranscriptionProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(transcriptionMethodDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ModelField(
                        label: "Transcription model",
                        value: $modelSettings.transcriptionModel,
                        presets: modelSettings.transcriptionProvider.models
                    )
                    ModelField(
                        label: "Note generation model",
                        value: $modelSettings.noteModel,
                        presets: ModelSettings.noteModels
                    )
                    ModelField(
                        label: "Language (BCP-47)",
                        value: $modelSettings.transcriptionLanguage,
                        presets: ["ko", "en", "ja", "zh", ""]
                    )
                    Text("Empty = auto-detect. Whisper auto-detection can misfire on short clips.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Model selections are saved automatically.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Note instructions

    private var noteInstructionsSection: some View {
        let count = modelSettings.noteInstructions.count
        let max = ModelSettings.noteInstructionsMaxLength
        let nearLimit = count > Int(Double(max) * 0.9)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            SectionTitle(
                text: "Note Generation Instructions",
                trailing: AnyView(
                    Text("\(count) / \(max)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(nearLimit ? BrandColor.warning : Color.secondary)
                )
            )
            Card {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Optional. Steer the summary's tone, audience, or structure. The JSON output schema stays fixed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $modelSettings.noteInstructions)
                        .font(.system(size: 13))
                        .frame(minHeight: 120)
                        .padding(Spacing.sm)
                        .background(BrandColor.surfaceElevated, in: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                                .strokeBorder(nearLimit ? BrandColor.warning.opacity(0.6) : BrandColor.border, lineWidth: 0.5)
                        )

                    HStack {
                        Text("Example: \"Focus on engineering decisions and call out unresolved questions.\"")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if !modelSettings.noteInstructions.isEmpty {
                            Button("Clear") {
                                modelSettings.noteInstructions = ""
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private var transcriptionMethodDescription: String {
        switch modelSettings.transcriptionProvider {
        case .audioAPI:
            return "Audio API uses the existing request/response transcription flow for recorded chunks."
        case .realtimeAPI:
            return "Realtime API streams each captured chunk through gpt-realtime-whisper."
        }
    }
}

private struct ModelField: View {
    let label: String
    @Binding var value: String
    let presets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(.callout.weight(.medium))
            HStack(spacing: Spacing.xs) {
                TextField("model name", text: $value)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset.isEmpty ? "(auto-detect)" : preset) { value = preset }
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
