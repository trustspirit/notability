import SwiftUI
import AppKit

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
            .contextMenu {
                Button(role: .destructive) {
                    delete(meeting)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                Button {
                    switch coordinator.state {
                    case .idle, .done, .failed:
                        coordinator.state = .idle
                        Task {
                            do {
                                try await coordinator.startRecording()
                            } catch {
                                await MainActor.run { showCaptureError(error) }
                            }
                        }
                    case .recording:
                        Task { await coordinator.stopRecording() }
                    case .processing:
                        break
                    }
                } label: {
                    switch coordinator.state {
                    case .idle, .done, .failed:
                        Label("Record", systemImage: "mic.circle.fill")
                    case .recording:
                        Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                    case .processing:
                        Label("Processing", systemImage: "hourglass")
                    }
                }
                .disabled({
                    if case .processing = coordinator.state { return true }
                    return false
                }())
            }
        }
    }

    private func delete(_ meeting: Meeting) {
        store.delete(id: meeting.id)
        if selectedMeetingId == meeting.id {
            selectedMeetingId = nil
        }
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording failed"
        if error.localizedDescription.lowercased().contains("permission") ||
           error.localizedDescription.lowercased().contains("access") {
            alert.informativeText = "Screen Recording permission is required.\n\nGo to System Settings → Privacy & Security → Screen Recording and enable Notability."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        } else {
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
