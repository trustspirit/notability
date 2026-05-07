import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var selectedMeetingId: UUID?

    var body: some View {
        NavigationSplitView {
            MeetingSidebarView(selectedMeetingId: $selectedMeetingId)
        } detail: {
            if let id = selectedMeetingId, let meeting = store.fetch(id: id) {
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
            if case .done(let id) = newState {
                selectedMeetingId = id
            }
        }
    }
}
