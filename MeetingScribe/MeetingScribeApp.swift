import SwiftUI

@main
struct MeetingScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window management is handled entirely by AppDelegate
        Settings { EmptyView() }
    }
}
