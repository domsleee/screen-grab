import AppKit
import HotKey
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var screenCaptureManager: ScreenCaptureManager?
    private var settingsWindow: NSWindow?

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
        menu.addItem(NSMenuItem(title: "Open Save Folder", action: #selector(openSaveFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
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

    @objc func openSaveFolder() {
        let path = AppSettings.shared.savePath
        let url = URL(fileURLWithPath: path)
        // Create the folder if it doesn't exist yet
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func openSettings() {
        // Reuse existing window if already open
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenGrab Settings"
        window.center()
        window.isReleasedWhenClosed = false

        guard let windowContentView = window.contentView else { return }
        let contentView = NSView(frame: windowContentView.bounds)
        contentView.autoresizingMask = [.width, .height]

        // "Save to:" label
        let label = NSTextField(labelWithString: "Save to:")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 20, y: 70, width: 60, height: 20)
        contentView.addSubview(label)

        // Path display
        let pathField = NSTextField(labelWithString: "")
        pathField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.frame = NSRect(x: 20, y: 40, width: 290, height: 20)
        pathField.stringValue = (AppSettings.shared.savePath as NSString).abbreviatingWithTildeInPath
        pathField.tag = 100
        contentView.addSubview(pathField)

        // "Change..." button
        let changeBtn = NSButton(title: "Change...", target: self, action: #selector(changeFolder(_:)))
        changeBtn.bezelStyle = .rounded
        changeBtn.frame = NSRect(x: 320, y: 36, width: 80, height: 28)
        contentView.addSubview(changeBtn)

        window.contentView = contentView
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func changeFolder(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: AppSettings.shared.savePath)
        panel.prompt = "Select"
        panel.message = "Choose save folder for screenshots"

        guard let window = settingsWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                AppSettings.shared.savePath = url.path
                // Update path label
                if let pathField = self?.settingsWindow?.contentView?.viewWithTag(100) as? NSTextField {
                    pathField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
                }
            }
        }
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
