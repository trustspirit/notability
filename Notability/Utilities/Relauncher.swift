import AppKit

/// Restarts the app so a newly granted permission takes effect, for the grants
/// macOS only applies to a fresh process.
///
/// The replacement must be launched *after* termination is settled, never before
/// asking for it. `NSApp.terminate` goes through `applicationShouldTerminate`,
/// which declines while a recording or a paid request is in flight, so a relaunch
/// is a request that the user is entitled to refuse. Launching first meant a
/// refusal left the app running with a second copy of itself already started.
@MainActor
final class Relauncher {
    private let launchSuccessor: () -> Void
    private var isRequested = false

    init(launchSuccessor: @escaping () -> Void) {
        self.launchSuccessor = launchSuccessor
    }

    /// Records the intent. The caller is expected to ask AppKit to terminate;
    /// whether that happens is up to `applicationShouldTerminate` and the user.
    func requestRelaunchAfterTermination() {
        isRequested = true
    }

    /// Call from `applicationWillTerminate`, which runs only once termination is
    /// actually going ahead. Close any open files before this: the replacement
    /// starts reading the meeting audio as soon as it launches.
    func launchSuccessorIfRequested() {
        guard isRequested else { return }
        isRequested = false
        launchSuccessor()
    }

    /// Starts a second instance of the running bundle. `-n` is required because
    /// this process is still alive at this point, and `open` would otherwise just
    /// activate it instead of starting a replacement.
    static func launchAnotherInstance() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
    }
}
