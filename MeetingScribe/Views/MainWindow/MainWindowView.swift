import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var selectedMeetingId: UUID?

    var body: some View {
        NavigationSplitView {
            MeetingSidebarView(selectedMeetingId: $selectedMeetingId)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
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
        .toolbar(removing: .sidebarToggle)
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

            WaveformBarsView(level: coordinator.audioLevel)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if !coordinator.systemAudioAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash")
                        .imageScale(.small)
                    Text("System audio unavailable — only your voice is captured. Grant Screen Recording in System Settings for full meeting transcription.")
                        .font(.caption)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.15))
            }

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
                        if let last = coordinator.liveTranscript.last {
                            withAnimation { proxy.scrollTo(last.timestamp, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

private struct WaveformBarsView: View {
    let level: Float
    private let barCount = 64
    @State private var history: [Float] = Array(repeating: 0, count: 64)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                // Fade bars near the edges for a natural look
                let edgeFade = edgeOpacity(i)
                Capsule()
                    .fill(.red.opacity(0.8 * edgeFade))
                    .frame(width: 3, height: max(2, CGFloat(history[i]) * 40 + 2))
            }
        }
        .frame(height: 44)
        .onChange(of: level) { _, newLevel in
            withAnimation(.linear(duration: 0.1)) {
                history.removeFirst()
                history.append(min(1.0, newLevel * 12))
            }
        }
    }

    private func edgeOpacity(_ index: Int) -> Double {
        let fadeZone = 8 // number of bars to fade on each side
        if index < fadeZone {
            return Double(index + 1) / Double(fadeZone + 1)
        } else if index >= barCount - fadeZone {
            return Double(barCount - index) / Double(fadeZone + 1)
        }
        return 1.0
    }
}
