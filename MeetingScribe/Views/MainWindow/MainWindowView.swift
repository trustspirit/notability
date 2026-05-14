import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var selectedMeetingId: UUID?

    var body: some View {
        NavigationSplitView {
            MeetingSidebarView(selectedMeetingId: $selectedMeetingId)
        } detail: {
            if case .recording = coordinator.state {
                LiveRecordingView()
            } else if let id = selectedMeetingId, let meeting = store.fetch(id: id) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "Select a meeting",
                    systemImage: "mic.circle",
                    description: Text("Your meeting notes will appear here.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onChange(of: coordinator.state) { _, newState in
            switch newState {
            case .done(let id):
                selectedMeetingId = id
            case .processing:
                // currentMeetingId is still set here (defer in stopRecording fires after this)
                selectedMeetingId = coordinator.currentMeetingId
            default:
                break
            }
        }
    }
}

private struct LiveRecordingView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.title2.bold())
                if case .recording(let elapsed) = coordinator.state {
                    Text(formatElapsed(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !coordinator.liveTranscript.isEmpty {
                    Text("\(coordinator.liveTranscript.filter { $0.text != "[transcription failed]" }.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            if coordinator.liveTranscript.isEmpty {
                ContentUnavailableView(
                    "Listening…",
                    systemImage: "waveform",
                    description: Text("Transcript will appear as speech is detected.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(coordinator.liveTranscript, id: \.timestamp) { chunk in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatTimestamp(chunk.timestamp))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .trailing)
                                        .padding(.top, 1)
                                    if chunk.text == "[transcription failed]" {
                                        Text(chunk.text)
                                            .foregroundStyle(.secondary)
                                            .italic()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(chunk.text)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .id(chunk.timestamp)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: coordinator.liveTranscript.count) { _, _ in
                        let last = coordinator.liveTranscript.count - 1
                        if last >= 0 {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        "\(Int(t) / 60):\(String(format: "%02d", Int(t) % 60))"
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
