// Temporary stubs — will be replaced by Tasks 11-12
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var coordinator: RecordingCoordinator

    var body: some View { Text("Loading\u{2026}") }
}

struct SettingsView: View {
    var body: some View { Text("Settings") }
}
