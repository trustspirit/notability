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

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MeetingStore()
        // Services read API key and model from Keychain/UserDefaults at each request —
        // no need to pass them at init or recreate on settings change
        let capture = AudioCaptureService()
        let transcription = TranscriptionService()
        let noteGen = NoteGenerationService()
        coordinator = RecordingCoordinator(
            audioCapture: capture,
            transcription: transcription,
            noteGeneration: noteGen,
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
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Start recording")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
        case .recording(let elapsed):
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            button.title = " \(String(format: "%d:%02d", mins, secs))"
        case .processing:
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Processing")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
        case .done:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Notes ready")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
        case .failed:
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Note generation failed")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
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
        case .processing:
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
        statusItem.popUpMenu(menu)
    }

    private func showRecordingMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.popUpMenu(menu)
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
            MeetingScribe needs Screen Recording access to capture audio.

            In System Settings → Privacy & Security → Screen Recording:
            • If MeetingScribe is not listed → add it, then relaunch
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
            alert.informativeText = "MeetingScribe needs Microphone access so your voice is included in the transcript.\n\nGo to System Settings → Privacy & Security → Microphone and enable MeetingScribe, then relaunch."
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
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
            window.title = "MeetingScribe"
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
        guard case .recording = coordinator.state else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "Do you want to stop recording and generate notes before quitting? This may take a moment.\n\nQuitting without saving will discard the current session."
        alert.addButton(withTitle: "Stop & Generate Notes")
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Continue Recording")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await coordinator.stopRecording()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

}
