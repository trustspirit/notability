import SwiftUI
import AppKit

struct MeetingSidebarView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @Binding var selectedMeetingId: UUID?
    @State private var search = ""
    @State private var pendingDeletion: Meeting?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            searchBar
            Divider().opacity(0.5)

            if filteredMeetings.isEmpty {
                BrandedEmptyState(
                    title: store.allMeetings.isEmpty ? "No meetings yet" : "No matches",
                    systemImage: store.allMeetings.isEmpty ? "mic.slash" : "magnifyingglass",
                    message: store.allMeetings.isEmpty
                        ? "Tap the button below to record your first meeting."
                        : "Try a different search term."
                )
            } else {
                meetingList
            }

            Divider().opacity(0.5)
            recordButton
        }
        .background(BrandColor.surfaceElevated)
        .navigationTitle("")
    }

    // MARK: - Header

    private var brandHeader: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(BrandColor.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Notability")
                    .font(.headline)
                Text("\(store.allMeetings.count) meeting\(store.allMeetings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Spacing.lg)
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search meetings…", text: $search)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(BrandColor.surface, in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }

    // MARK: - List (native — preserves keyboard nav + focus + selection a11y)

    private var meetingList: some View {
        List(filteredMeetings, selection: $selectedMeetingId) { meeting in
            MeetingRow(meeting: meeting, onDelete: { confirmDelete(meeting) })
                .tag(meeting.id)
                .contextMenu {
                    Button(role: .destructive) {
                        confirmDelete(meeting)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            // `onDeleteCommand` listens on the window responder chain, so it can
            // fire while the search field is focused (e.g. emptying the query
            // with backspace). Skip in that case.
            guard !searchFocused,
                  let id = selectedMeetingId,
                  let meeting = filteredMeetings.first(where: { $0.id == id }) else { return }
            confirmDelete(meeting)
        }
        .alert(
            "Delete meeting?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { meeting in
            Button("Delete", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { meeting in
            Text("\"\(meeting.title)\" will be permanently deleted. This can't be undone.")
        }
    }

    private var filteredMeetings: [Meeting] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return store.allMeetings }
        return store.allMeetings.filter {
            $0.title.lowercased().contains(term) ||
            ($0.notes?.summary.lowercased().contains(term) ?? false)
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        Group {
            switch coordinator.state {
            case .idle, .done, .failed:
                PrimaryActionButton(title: "Record", systemImage: "mic.fill", tint: BrandColor.accent) {
                    Task {
                        do { try await coordinator.startRecording() }
                        catch { await MainActor.run { showCaptureError(error) } }
                    }
                }
            case .recording:
                PrimaryActionButton(title: "Stop Recording", systemImage: "stop.fill", tint: BrandColor.recording) {
                    Task { await coordinator.stopRecording() }
                }
            case .processing:
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Generating notes…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(BrandColor.surface, in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            }
        }
        .padding(Spacing.lg)
    }

    private func confirmDelete(_ meeting: Meeting) {
        pendingDeletion = meeting
    }

    private func delete(_ meeting: Meeting) {
        store.delete(id: meeting.id)
        if selectedMeetingId == meeting.id {
            selectedMeetingId = nil
        }
        pendingDeletion = nil
    }

    private func showCaptureError(_ error: Error) {
        (NSApp.delegate as? AppDelegate)?.showRecordingError(error)
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting
    var onDelete: (() -> Void)? = nil
    @State private var hover = false

    // Static formatter — instantiating RelativeDateTimeFormatter is non-trivial
    // and the sidebar re-renders frequently.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            statusIndicator
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Text(Self.relativeFormatter.localizedString(for: meeting.date, relativeTo: Date()))
                    Text("·")
                    Text(formatDuration(meeting.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusBadge
            if hover, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Delete meeting (⌫)")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { hover = hovering }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if meeting.notes == nil && meeting.notesGenerationError == nil {
            Image(systemName: "hourglass")
                .imageScale(.small)
                .foregroundStyle(BrandColor.warning)
        } else if meeting.notesGenerationError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(BrandColor.warning)
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 6, height: 6)
    }

    private var indicatorColor: Color {
        if meeting.notesGenerationError != nil { return BrandColor.warning }
        if meeting.notes == nil { return BrandColor.warning.opacity(0.6) }
        return BrandColor.success
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins == 0 { return "\(secs)s" }
        return "\(mins)m \(secs)s"
    }
}
