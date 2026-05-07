import SwiftUI

struct MeetingSidebarView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @Binding var selectedMeetingId: UUID?

    var body: some View {
        List(store.allMeetings, selection: $selectedMeetingId) { meeting in
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(meeting.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if meeting.notes == nil && meeting.notesGenerationError == nil {
                    Label("Processing…", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                Button {
                    if case .idle = coordinator.state {
                        Task { try? await coordinator.startRecording() }
                    } else if case .recording = coordinator.state {
                        Task { await coordinator.stopRecording() }
                    }
                } label: {
                    switch coordinator.state {
                    case .idle:
                        Label("Record", systemImage: "mic.circle.fill")
                    case .recording:
                        Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                    case .processing:
                        Label("Processing", systemImage: "hourglass")
                    default:
                        Label("Record", systemImage: "mic.circle.fill")
                    }
                }
            }
        }
    }
}
