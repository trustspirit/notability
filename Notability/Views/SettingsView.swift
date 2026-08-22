import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false
    @State private var keyIsSaved = false
    /// nil until the on-device availability lookup answers for the current language.
    @State private var liveCaptionsSupported: Bool?
    @ObservedObject private var modelSettings = ModelSettings.shared

    private let keychainKey = "com.notability.openai-api-key"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                apiKeySection
                modelsSection
                noteInstructionsSection
            }
            .padding(Spacing.xl)
            .overlayScrollerStyle()
        }
        .frame(width: 520, height: 640)
        .background(BrandColor.surfaceElevated)
        .onAppear {
            let stored = CredentialsStore.load(forKey: keychainKey) ?? ""
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
                            CredentialsStore.save(apiKey, forKey: keychainKey)
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
                                CredentialsStore.delete(forKey: keychainKey)
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

                    Text("Stored in ~/Library/Application Support/Notability/ with owner-only file permissions.")
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
                    Text("Empty = auto-detect for the final transcript. Live captions have no auto-detect and fall back to this Mac's language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    liveCaptionsRow

                    Text("Model selections are saved automatically.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The privacy line holds regardless of language, so it is stated
    /// unconditionally and the availability lookup only ever adds a caveat. That
    /// keeps the row honest while `liveCaptionsSupported` is still nil — during
    /// the lookup, or if it never answers — without a spinner or a placeholder.
    private var liveCaptionsRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Live captions")
                .font(.callout.weight(.medium))
            Text("Transcribed on this Mac while you record. No audio leaves your device for captions, and they add nothing to your API bill.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if liveCaptionsSupported == false {
                Text("This language has no on-device model, so no captions appear while recording. The final transcript is unaffected.")
                    .font(.caption)
                    .foregroundStyle(BrandColor.warning)
            }
        }
        // Re-runs when the language changes, because the answer depends on it and
        // the field that changes it is directly above.
        .task(id: modelSettings.effectiveTranscriptionLocaleIdentifier) {
            let identifier = modelSettings.effectiveTranscriptionLocaleIdentifier
            liveCaptionsSupported = nil
            liveCaptionsSupported = await LiveTranscriptionService.isSupported(
                locale: Locale(identifier: identifier)
            )
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
