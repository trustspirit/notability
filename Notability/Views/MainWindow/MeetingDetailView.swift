import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var selectedTab: DetailTab = .summary
    @State private var titleInput = ""
    @State private var titleHover = false
    @FocusState private var titleFocused: Bool

    enum DetailTab: Hashable {
        case summary, actions, decisions, transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            tabBar
            content
        }
        .background(BrandColor.surfaceElevated)
        .onAppear { titleInput = meeting.title }
        .onChange(of: meeting.title) { _, new in titleInput = new }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    TextField("Meeting title", text: $titleInput)
                        .font(.title.weight(.bold))
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        // Single commit path: defer to the focus-change handler so
                        // Enter and blur both flow through one call site.
                        .onSubmit { titleFocused = false }
                        .onChange(of: titleFocused) { _, isFocused in
                            if !isFocused { commitTitle() }
                        }
                    if titleFocused {
                        Image(systemName: "pencil.circle.fill")
                            .font(.callout)
                            .foregroundStyle(BrandColor.accent)
                            .transition(.opacity)
                    } else if titleHover {
                        Image(systemName: "pencil")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                        .fill(titleFocused
                              ? BrandColor.accent.opacity(0.08)
                              : (titleHover ? Color.primary.opacity(0.05) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                        .strokeBorder(titleFocused ? BrandColor.accent.opacity(0.4) : .clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { titleHover = hovering }
                }
                .onTapGesture { titleFocused = true }
                .help("Click to rename meeting")
                HStack(spacing: Spacing.sm) {
                    Label(meeting.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Label(formatDuration(meeting.durationSeconds), systemImage: "clock")
                    // Absent for meetings transcribed before this was recorded, and
                    // for any meeting whose transcription never succeeded. Shown
                    // next to the wall-clock duration because the two differ: the
                    // API bills the mixed audio it actually processed.
                    if let billed = meeting.billedSeconds {
                        Label("Billed \(formatDuration(Double(billed)))", systemImage: "creditcard")
                            .help("Audio billed by the transcription API for this meeting. Live captions during the meeting were free.")
                    }
                    if meeting.notes == nil && meeting.notesGenerationError == nil {
                        Pill(text: "Generating", systemImage: "sparkles", tint: BrandColor.warning)
                    } else if meeting.notesGenerationError != nil {
                        Pill(text: "Failed", systemImage: "exclamationmark.triangle.fill", tint: BrandColor.warning)
                    } else {
                        Pill(text: "Notes ready", systemImage: "checkmark.circle.fill", tint: BrandColor.success)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.notes != nil {
                Button {
                    copyNotes()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Copy all notes to clipboard")
            }
        }
        .padding(Spacing.lg)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.summary, title: "Summary", systemImage: "text.alignleft", shortcut: "1")
            tabButton(.actions, title: "Action Items", systemImage: "checkmark.circle", count: meeting.notes?.actionItems.count, shortcut: "2")
            tabButton(.decisions, title: "Decisions", systemImage: "arrow.triangle.branch", count: meeting.notes?.keyDecisions.count, shortcut: "3")
            tabButton(.transcript, title: "Transcript", systemImage: "text.bubble", count: meeting.transcript.count, shortcut: "4")
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
    }

    @ViewBuilder
    private func tabButton(_ tab: DetailTab, title: String, systemImage: String, count: Int? = nil, shortcut: KeyEquivalent? = nil) -> some View {
        let isActive = selectedTab == tab
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: systemImage)
                    Text(title)
                        .fontWeight(isActive ? .semibold : .regular)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isActive ? BrandColor.accent.opacity(0.18) : Color.secondary.opacity(0.12))
                            )
                    }
                }
                .font(.callout)
                .foregroundStyle(isActive ? BrandColor.accent : Color.secondary)

                Rectangle()
                    .fill(isActive ? BrandColor.accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalShortcut(key: shortcut))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let notes = meeting.notes {
            switch selectedTab {
            case .summary:
                SummaryTabView(summary: notes.summary)
            case .actions:
                ActionItemsTabView(items: notes.actionItems) { itemId in
                    store.toggleActionItemCompleted(meetingId: meeting.id, itemId: itemId)
                }
            case .decisions:
                KeyDecisionsTabView(decisions: notes.keyDecisions)
            case .transcript:
                TranscriptTabView(chunks: meeting.transcript)
            }
        } else if let error = meeting.transcriptionError {
            // Checked before notesGenerationError because transcription runs
            // first: if it failed there are no notes to have failed at.
            BrandedEmptyState(
                title: "Transcription failed",
                systemImage: "exclamationmark.triangle.fill",
                message: error,
                action: retryAction
            )
        } else if let error = meeting.notesGenerationError {
            BrandedEmptyState(
                title: "Note generation failed",
                systemImage: "exclamationmark.triangle.fill",
                message: error,
                action: retryAction
            )
        } else {
            BrandedEmptyState(
                title: "Generating notes…",
                systemImage: "sparkles",
                message: "Notability is summarizing your meeting. This usually takes under a minute."
            )
        }
    }

    /// Retrying re-reads the recorded audio, so it is only offered while that
    /// audio is still on disk. It is deleted once notes exist.
    private var retryAction: (String, () -> Void)? {
        guard meeting.audioDirectory != nil else { return nil }
        return ("Retry", { coordinator.retryProcessing(meetingId: meeting.id) })
    }

    private func commitTitle() {
        let trimmed = titleInput.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            titleInput = meeting.title
        } else {
            store.rename(id: meeting.id, title: trimmed)
        }
    }

    private func copyNotes() {
        guard let notes = meeting.notes else { return }
        var lines = ["# \(meeting.title)", ""]
        lines += ["## Summary", notes.summary, ""]
        if !notes.actionItems.isEmpty {
            lines.append("## Action Items")
            for item in notes.actionItems {
                var line = "- [\(item.isCompleted ? "x" : " ")] \(item.description)"
                if let a = item.assignee { line += " (@\(a))" }
                if let d = item.dueDate { line += " (due: \(d))" }
                lines.append(line)
            }
            lines.append("")
        }
        if !notes.keyDecisions.isEmpty {
            lines.append("## Key Decisions")
            notes.keyDecisions.forEach { lines.append("- \($0)") }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins == 0 { return "\(secs)s" }
        return "\(mins)m \(secs)s"
    }
}

// macOS-style shortcut helper — only applies the modifier when a key is provided.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: [.command])
        } else {
            content
        }
    }
}
