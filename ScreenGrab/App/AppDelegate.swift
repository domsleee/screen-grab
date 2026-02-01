import AppKit
import HotKey
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var screenCaptureManager: ScreenCaptureManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("ScreenGrab starting up")
        setupStatusItem()
        setupHotKey()
        screenCaptureManager = ScreenCaptureManager()

        // Request screen recording permission on startup
        requestScreenRecordingPermission()
        logInfo("ScreenGrab ready")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ScreenGrab")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture Region (⌘⇧2)", action: #selector(startCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func setupHotKey() {
        // Cmd+Shift+2 for capture (avoids conflict with macOS native ⌘⇧4)
        hotKey = HotKey(key: .two, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            self?.startCapture()
        }
        logDebug("Hotkey registered: Cmd+Shift+2")
    }

    @objc func startCapture() {
        logInfo("Capture triggered")
        screenCaptureManager?.startCapture()
    }

    private func requestScreenRecordingPermission() {
        // Temporarily become regular app so permission dialog stays open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Use ScreenCaptureKit to trigger permission request
        Task {
            do {
                // This will trigger the permission dialog and WAIT for user response
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                logInfo("Screen recording permission granted, found \(content.displays.count) displays")

                // Permission granted - go back to accessory mode
                await MainActor.run {
                    NSApp.setActivationPolicy(.accessory)
                }
            } catch {
                logError("Screen recording permission denied or error: \(error)")
                // Show alert to user
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording Permission Required"
                    alert.informativeText = "Please grant Screen Recording permission in System Settings " +
                        "→ Privacy & Security → Screen Recording, then restart ScreenGrab."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Quit")

                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        if let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
