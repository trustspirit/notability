import AppKit
import SwiftUI
import UserNotifications
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private(set) var store: MeetingStore!
    private(set) var coordinator: RecordingCoordinator!
    private var stateObserver: Task<Void, Never>?

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
        checkScreenRecordingPermission()
    }

    private func observeCoordinatorState() {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            guard let self else { return }
            for await _ in self.coordinator.$state.values {
                self.updateStatusIcon(state: self.coordinator.state)
                if case .done = self.coordinator.state {
                    self.openMainWindow()
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
        case .done, .failed:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Meeting ready - click to view notes")
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
            showMenu()
        case .recording:
            Task { await coordinator.stopRecording() }
        case .processing:
            break
        case .done, .failed:
            openMainWindow()
            coordinator.resetToIdle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.popUpMenu(menu)
    }

    @objc private func startRecording() {
        Task {
            do {
                try await coordinator.startRecording()
            } catch {
                showRecordingPermissionAlert()
            }
        }
    }

    private func checkScreenRecordingPermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Notability needs Screen Recording access to capture meeting audio.\n\nClick \"Open Settings\" to grant access, then relaunch the app."
        alert.addButton(withTitle: "Open Settings & Quit")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
            NSApp.terminate(nil)
        }
    }

    private func showRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Required"
        alert.informativeText = "Go to System Settings → Privacy & Security → Screen Recording and enable Notability.\n\nAfter enabling, you must relaunch the app for the change to take effect."
        alert.addButton(withTitle: "Open Settings & Relaunch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            relaunch()
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

}
