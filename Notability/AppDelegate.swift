import AppKit
import SwiftUI
import UserNotifications
import AVFoundation
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private(set) var store: MeetingStore!
    private(set) var coordinator: RecordingCoordinator!
    private var stateObserver: Task<Void, Never>?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Status icon updates fire every second during recording; pre-create the
    // SF Symbol images once instead of allocating new NSImages each tick.
    private lazy var statusIcons: [String: NSImage] = {
        let names = ["mic", "mic.fill", "hourglass", "exclamationmark.circle"]
        var dict: [String: NSImage] = [:]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: name) {
                dict[name] = image
            }
        }
        return dict
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MeetingStore()
        // Services read the API key from CredentialsStore and the model from
        // UserDefaults at each request — no need to pass them at init or
        // recreate anything when settings change
        coordinator = RecordingCoordinator(
            audioCapture: AudioCaptureService(),
            // A live transcription service is single use: its event stream ends
            // when the recording does, so each recording needs a new one.
            makeLiveTranscription: { LiveTranscriptionService() },
            finalTranscription: DiarizedTranscriptionService(),
            noteGeneration: NoteGenerationService(),
            store: store
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(state: .idle)

        requestNotificationPermission()
        observeCoordinatorState()
        // Request mic permission silently on first launch (system dialog, non-blocking).
        // Screen Recording is checked lazily — only when recording fails — to avoid
        // false positives from CGPreflightScreenCaptureAccess on ad-hoc builds.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            checkMicrophonePermission()
        }
    }

    private func observeCoordinatorState() {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            guard let self else { return }
            for await _ in self.coordinator.$state.values {
                self.updateStatusIcon(state: self.coordinator.state)
                switch self.coordinator.state {
                case .done, .failed:
                    self.openMainWindow()
                default:
                    break
                }
            }
        }
    }

    private func updateStatusIcon(state: RecordingState) {
        guard let button = statusItem.button else { return }
        let icon: NSImage?
        let isTemplate: Bool
        let tint: NSColor?
        let title: String
        switch state {
        case .idle:
            icon = statusIcons["mic"]; isTemplate = true; tint = nil; title = ""
        case .recording(let elapsed):
            icon = statusIcons["mic.fill"]; isTemplate = false; tint = .systemRed
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            title = " \(String(format: "%d:%02d", mins, secs))"
        case .transcribing, .generatingNotes:
            icon = statusIcons["hourglass"]; isTemplate = true; tint = nil; title = ""
        case .done:
            icon = statusIcons["mic"]; isTemplate = true; tint = nil; title = ""
        case .failed:
            icon = statusIcons["exclamationmark.circle"]; isTemplate = true; tint = nil; title = ""
        }
        // Only reassign the image when it actually changes — repeatedly setting
        // the same NSImage churns the SF Symbol cache that crashed in 1.3.0.
        if button.image !== icon {
            button.image = icon
            button.image?.isTemplate = isTemplate
        }
        if button.contentTintColor != tint {
            button.contentTintColor = tint
        }
        if button.title != title {
            button.title = title
        }
        button.action = #selector(handleStatusBarClick)
        button.target = self
    }

    @objc private func handleStatusBarClick() {
        switch coordinator.state {
        case .idle:
            showIdleMenu()
        case .recording:
            showRecordingMenu()
        case .transcribing, .generatingNotes:
            break
        case .done, .failed:
            openMainWindow()
            coordinator.resetToIdle()
        }
    }

    private func showIdleMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        popUpStatusBarMenu(menu)
    }

    private func showRecordingMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        popUpStatusBarMenu(menu)
    }

    // Modern replacement for the deprecated NSStatusItem.popUpMenu(_:). Anchors
    // the menu just below the status item button, mirroring native behavior.
    private func popUpStatusBarMenu(_ menu: NSMenu) {
        guard let button = statusItem.button else { return }
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func startRecording() {
        Task {
            do {
                try await coordinator.startRecording()
            } catch {
                showRecordingError(error)
            }
        }
    }

    @objc private func stopRecording() {
        Task { await coordinator.stopRecording() }
    }

    func showRecordingError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Required"
        // On ad-hoc builds the binary hash changes with each update, so macOS
        // may show the app as enabled in Settings but still deny access.
        // Toggling the switch OFF → ON re-associates the permission with the
        // current binary and resolves the issue.
        alert.informativeText = """
            Notability needs Screen Recording access to capture audio.

            In System Settings → Privacy & Security → Screen Recording:
            • If Notability is not listed → add it, then relaunch
            • If it is already enabled → toggle OFF, then ON, then relaunch
            """
        alert.addButton(withTitle: "Open Settings & Relaunch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            relaunch()
        }
    }

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }  // system dialog; result handled on next launch
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Notability needs Microphone access so your voice is included in the transcript.\n\nGo to System Settings → Privacy & Security → Microphone and enable Notability, then relaunch."
            alert.addButton(withTitle: "Open Settings & Relaunch")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                relaunch()
            }
        @unknown default:
            break
        }
    }

    private func relaunch() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openNotes() { openMainWindow() }

    @objc private func openSettings() {
        if let window = settingsWindow {
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            settingsWindow = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // Without this, AppKit releases the window when the user closes it,
        // leaving `settingsWindow` as a dangling pointer that crashes
        // (objc_retain) on the next openSettings() call.
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func openMainWindow() {
        if mainWindow == nil {
            let contentView = MainWindowView()
                .environmentObject(store)
                .environmentObject(coordinator)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Notability"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.setFrameAutosaveName("MainWindow")
            window.isReleasedWhenClosed = false  // keep alive when closed
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch QuitPolicy.decision(for: coordinator.state) {
        case .quitNow:
            return .terminateNow
        case .ask(let prompt):
            // A dismissal that matches no button is treated as "don't quit",
            // which is the only safe reading while something is in flight.
            guard let choice = present(prompt) else { return .terminateCancel }
            return reply(to: choice)
        }
    }

    private func present(_ prompt: QuitPrompt) -> QuitChoice? {
        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        for choice in prompt.choices {
            alert.addButton(withTitle: choice.buttonTitle)
        }
        let index = alert.runModal().rawValue
            - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard prompt.choices.indices.contains(index) else { return nil }
        return prompt.choices[index]
    }

    private func reply(to choice: QuitChoice) -> NSApplication.TerminateReply {
        switch choice.effect {
        case .quitNow:
            return .terminateNow
        case .cancelQuit:
            return .terminateCancel
        case .quitAfter(let work):
            Task {
                switch work {
                case .stopRecordingAndProcess:
                    await coordinator.stopRecording()
                case .saveRecordedAudio:
                    await coordinator.saveRecordingForLater()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// Last chance to close the recording's audio files.
    ///
    /// `applicationShouldTerminate` never lets a recording reach here unclosed,
    /// so in the ordinary flow this does nothing. It exists for the terminations
    /// that do not go through the prompt at all — a logout that AppKit does not
    /// let an app block, or any future path that quits without asking — because
    /// an audio file that was never closed cannot be decoded, and the whole
    /// point of keeping the audio is that it can be read later.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.finalizeAudioForTermination()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

}
