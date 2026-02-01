import AppKit
import HotKey

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var screenCaptureManager: ScreenCaptureManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        screenCaptureManager = ScreenCaptureManager()
        
        // Check screen recording permission
        checkScreenRecordingPermission()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShareX Mac")
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
    }
    
    @objc func startCapture() {
        screenCaptureManager?.startCapture()
    }
    
    private func checkScreenRecordingPermission() {
        let hasPermission = CGPreflightScreenCaptureAccess()
        if !hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }
}
