import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private(set) var store: MeetingStore!
    private(set) var coordinator: RecordingCoordinator!
    private var stateObserver: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MeetingStore()
        let apiKey = KeychainHelper.load(forKey: "com.meetingscribe.openai-api-key") ?? ""
        let capture = AudioCaptureService()
        let transcription = TranscriptionService(apiKey: apiKey)
        let noteGen = NoteGenerationService(apiKey: apiKey)
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
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MeetingScribe")
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
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MeetingScribe")
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
            coordinator.state = .idle
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
        Task { try? await coordinator.startRecording() }
    }

    @objc private func openNotes() { openMainWindow() }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMainWindow() {
        if let window = mainWindow {
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            mainWindow = nil  // release closed window
        }
        let contentView = MainWindowView()
            .environmentObject(store)
            .environmentObject(coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Scribe"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
