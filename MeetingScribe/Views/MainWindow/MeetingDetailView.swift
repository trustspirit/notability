import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject var store: MeetingStore
    @State private var selectedTab = 0
    @State private var titleInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    TextField("Meeting title", text: $titleInput)
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .onSubmit { commitTitle() }
                    (Text(meeting.date, style: .date) + Text(" · ") + Text(formatDuration(meeting.durationSeconds)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if meeting.notes != nil {
                    Button {
                        copyNotes()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy all notes to clipboard")
                    .buttonStyle(.borderless)
                }
            }
            .padding()

            Divider()

            if let notes = meeting.notes {
                TabView(selection: $selectedTab) {
                    SummaryTabView(summary: notes.summary)
                        .tabItem { Label("Summary", systemImage: "text.alignleft") }
                        .tag(0)
                    ActionItemsTabView(items: notes.actionItems) { itemId in
                        store.toggleActionItemCompleted(meetingId: meeting.id, itemId: itemId)
                    }
                    .tabItem { Label("Action Items", systemImage: "checkmark.circle") }
                    .tag(1)
                    KeyDecisionsTabView(decisions: notes.keyDecisions)
                        .tabItem { Label("Decisions", systemImage: "arrow.triangle.branch") }
                        .tag(2)
                    TranscriptTabView(chunks: meeting.transcript)
                        .tabItem { Label("Transcript", systemImage: "text.bubble") }
                        .tag(3)
                }
                .padding()
            } else if let error = meeting.notesGenerationError {
                ContentUnavailableView(
                    "Note generation failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Generating notes…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { titleInput = meeting.title }
        .onChange(of: meeting.title) { _, new in titleInput = new }
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
        return "\(mins)m \(secs)s"
    }
}
