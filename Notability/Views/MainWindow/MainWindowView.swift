import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var selectedMeetingId: UUID?

    var body: some View {
        NavigationSplitView {
            MeetingSidebarView(selectedMeetingId: $selectedMeetingId)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            VStack(spacing: 0) {
                // Above the detail content rather than inside any one view: the
                // recording has already ended by the time this is set, so there is
                // no recording screen left to put it on, and it explains the app's
                // behaviour rather than the selected meeting's.
                if let notice = coordinator.recordingInterruptedNotice {
                    WarningBanner(
                        title: "Recording stopped unexpectedly",
                        message: notice,
                        systemImage: "mic.slash.fill",
                        action: ("Dismiss", { coordinator.dismissRecordingInterruptedNotice() })
                    )
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.lg)
                }
                detailContent
            }
            .background(BrandColor.surfaceElevated)
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: coordinator.state) { _, newState in
            switch newState {
            case .done(let id):
                selectedMeetingId = id
            case .transcribing(let id):
                selectedMeetingId = id
            default:
                break
            }
        }
    }

    private var detailContent: some View {
        Group {
            if case .recording = coordinator.state {
                LiveRecordingView()
            } else if let id = selectedMeetingId, let meeting = store.fetch(id: id) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)  // force fresh @State (selectedTab, titleInput) per meeting
            } else if case .transcribing = coordinator.state {
                BrandedEmptyState(
                    title: "Transcribing the recording…",
                    systemImage: "waveform",
                    message: "The whole meeting is transcribed in one pass so speakers can be told apart."
                )
            } else if case .generatingNotes = coordinator.state {
                BrandedEmptyState(
                    title: "Generating meeting notes…",
                    systemImage: "sparkles",
                    message: "We're turning your conversation into structured notes."
                )
            } else {
                BrandedEmptyState(
                    title: store.allMeetings.isEmpty ? "Welcome to Notability" : "Select a meeting",
                    systemImage: store.allMeetings.isEmpty ? "waveform.circle" : "list.bullet",
                    message: store.allMeetings.isEmpty
                        ? "Press the Record button to capture your first meeting. Notability transcribes audio and generates a summary, action items, and decisions."
                        : "Pick a meeting from the sidebar to view its summary and action items."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live recording

private struct LiveRecordingView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator

    var body: some View {
        let transcriptRows = coordinator.visibleLiveTranscript

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            waveform
            captureWarning
            transcriptArea(rows: transcriptRows)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandColor.surfaceElevated)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            PulsingDot(color: BrandColor.recording, size: 10)
                .padding(.leading, Spacing.xs)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                    .font(.title2.weight(.bold))
                if case .recording(let elapsed) = coordinator.state {
                    Text(formatElapsed(elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: Spacing.sm) {
                let rowCount = coordinator.visibleLiveTranscript.count
                if rowCount > 0 {
                    Pill(text: "\(rowCount) segment\(rowCount == 1 ? "" : "s")", systemImage: "text.bubble", tint: BrandColor.accent)
                }
                if let notice = coordinator.liveCaptionNotice {
                    Pill(text: notice, systemImage: "captions.bubble", tint: BrandColor.warning)
                }
                Button {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.recording)
                .controlSize(.regular)
                .keyboardShortcut(".", modifiers: [.command])
            }
        }
        .padding(Spacing.lg)
    }

    private var waveform: some View {
        WaveformBarsView(level: coordinator.audioLevel)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
    }

    /// Only ever one banner: stacking two turns the recording view into a wall of
    /// warnings for what is a common setup.
    ///
    /// Both conditions can hold at once, but the echo-cancellation warning is
    /// only *true* when system audio is being captured — the duplication it warns
    /// about needs that second copy of the far end. With no system track there is
    /// one copy either way, so when system audio is missing that warning would be
    /// a false alarm on top of the more serious problem that half the meeting is
    /// not being recorded.
    @ViewBuilder
    private var captureWarning: some View {
        if !coordinator.systemAudioAvailable {
            WarningBanner(
                title: "System audio unavailable",
                message: "Only your microphone is being captured. Grant Screen Recording in System Settings for full meeting transcription.",
                systemImage: "speaker.slash.fill",
                action: ("Open Settings", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                })
            )
            .padding(.horizontal, Spacing.lg)
        } else if !coordinator.echoCancellationEnabled {
            WarningBanner(
                title: "Echo cancellation unavailable",
                message: "If you are on speakers, the other side will also reach your microphone, so their words can appear twice and be attributed to you. Headphones avoid this.",
                systemImage: "speaker.wave.2.fill"
            )
            .padding(.horizontal, Spacing.lg)
        }
    }

    @ViewBuilder
    private func transcriptArea(rows: [TranscriptChunk]) -> some View {
        if rows.isEmpty {
            BrandedEmptyState(
                title: "Listening…",
                systemImage: "waveform",
                message: coordinator.liveCaptionNotice
                    ?? "Start speaking and Notability will caption in real time."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(rows.identifiedRows()) { row in
                            TranscriptRow(chunk: row.chunk)
                                .id(row.id)
                        }
                    }
                    .padding(Spacing.lg)
                }
                .onChange(of: rows.count) { _, _ in
                    scrollToLast(proxy, total: rows.count)
                }
                .onChange(of: rows.last?.text ?? "") { _, _ in
                    scrollToLast(proxy, total: rows.count)
                }
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, total: Int) {
        let lastIndex = total - 1
        guard lastIndex >= 0 else { return }
        // No withAnimation: partial-transcript updates are very frequent and
        // overlapping scroll animations were a measurable layout-engine pressure.
        proxy.scrollTo(lastIndex, anchor: .bottom)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        "\(Int(t) / 60):\(String(format: "%02d", Int(t) % 60))"
    }
}

// MARK: - Waveform

private struct WaveformBarsView: View {
    let level: Float
    private let barCount = 64
    @State private var history: [Float] = Array(repeating: 0, count: 64)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let edgeFade = edgeOpacity(i)
                Capsule()
                    .fill(BrandColor.recording.opacity(0.75 * edgeFade))
                    .frame(width: 3, height: max(2, CGFloat(history[i]) * 44 + 2))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(BrandColor.surface, in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(BrandColor.border, lineWidth: 0.5)
        )
        .onChange(of: level) { _, newLevel in
            // Animation duration must exceed the upstream throttle interval (~50ms)
            // so consecutive updates overlap and the bars glide instead of "tick"
            // discretely. Linear easing makes the wave feel like a continuous
            // signal rather than a series of settles.
            withAnimation(.linear(duration: 0.12)) {
                history.removeFirst()
                history.append(min(1.0, newLevel * 8))
            }
        }
    }

    private func edgeOpacity(_ index: Int) -> Double {
        let fadeZone = 8
        if index < fadeZone {
            return Double(index + 1) / Double(fadeZone + 1)
        } else if index >= barCount - fadeZone {
            return Double(barCount - index) / Double(fadeZone + 1)
        }
        return 1.0
    }
}
