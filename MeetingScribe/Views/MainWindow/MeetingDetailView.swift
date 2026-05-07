import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(meeting.title)
                        .font(.title2.bold())
                    (Text(meeting.date, style: .date) + Text(" · ") + Text(formatDuration(meeting.durationSeconds)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            if let notes = meeting.notes {
                TabView(selection: $selectedTab) {
                    SummaryTabView(summary: notes.summary)
                        .tabItem { Label("Summary", systemImage: "text.alignleft") }
                        .tag(0)
                    ActionItemsTabView(items: notes.actionItems)
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
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Generating notes…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }
}
