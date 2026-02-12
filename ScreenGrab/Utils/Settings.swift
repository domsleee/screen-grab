import Foundation

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // Keys
    private enum Key: String {
        case loggingEnabled
        case logLevel
        case hotkey
        case hotkeyModifiers
        case annotationColor
        case strokeWidth
        case copyToClipboard
        case playSound
        case savePath
    }

    private init() {
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.loggingEnabled.rawValue: true,  // Enabled by default for now
            Key.logLevel.rawValue: "debug",     // Debug level for now
            Key.hotkey.rawValue: 19, // Key code for "2"
            Key.hotkeyModifiers.rawValue: 768, // Cmd+Shift
            Key.annotationColor.rawValue: "red",
            Key.strokeWidth.rawValue: 3.0,
            Key.copyToClipboard.rawValue: true,
            Key.playSound.rawValue: true,
            Key.savePath.rawValue: ("~/Pictures/ScreenGrab" as NSString).expandingTildeInPath,
            "textBackgroundOpacity": 0.75
        ])
    }

    // MARK: - Logging

    var loggingEnabled: Bool {
        get {
            // Environment variable overrides setting
            if let envValue = ProcessInfo.processInfo.environment["SCREENGRAB_LOG"] {
                return envValue == "1" || envValue.lowercased() == "true"
            }
            return defaults.bool(forKey: Key.loggingEnabled.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.loggingEnabled.rawValue) }
    }

    var logLevel: String {
        get {
            // Environment variable overrides setting
            if let envValue = ProcessInfo.processInfo.environment["SCREENGRAB_LOG_LEVEL"] {
                return envValue.lowercased()
            }
            return defaults.string(forKey: Key.logLevel.rawValue) ?? "info"
        }
        set { defaults.set(newValue, forKey: Key.logLevel.rawValue) }
    }

    // MARK: - Hotkey

    var hotkeyCode: UInt32 {
        get { UInt32(defaults.integer(forKey: Key.hotkey.rawValue)) }
        set { defaults.set(Int(newValue), forKey: Key.hotkey.rawValue) }
    }

    var hotkeyModifiers: UInt32 {
        get { UInt32(defaults.integer(forKey: Key.hotkeyModifiers.rawValue)) }
        set { defaults.set(Int(newValue), forKey: Key.hotkeyModifiers.rawValue) }
    }

    // MARK: - Capture

    var annotationColor: String {
        get { defaults.string(forKey: Key.annotationColor.rawValue) ?? "red" }
        set { defaults.set(newValue, forKey: Key.annotationColor.rawValue) }
    }

    var annotationColorRGBA: [CGFloat]? {
        get { defaults.array(forKey: "annotationColorRGBA") as? [CGFloat] }
        set { defaults.set(newValue, forKey: "annotationColorRGBA") }
    }

    var textBackgroundColorRGBA: [CGFloat]? {
        get { defaults.array(forKey: "textBackgroundColorRGBA") as? [CGFloat] }
        set { defaults.set(newValue, forKey: "textBackgroundColorRGBA") }
    }

    var textBackgroundOpacity: CGFloat {
        get { CGFloat(defaults.double(forKey: "textBackgroundOpacity")) }
        set { defaults.set(Double(newValue), forKey: "textBackgroundOpacity") }
    }

    var strokeWidth: Double {
        get { defaults.double(forKey: Key.strokeWidth.rawValue) }
        set { defaults.set(newValue, forKey: Key.strokeWidth.rawValue) }
    }

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: Key.copyToClipboard.rawValue) }
        set { defaults.set(newValue, forKey: Key.copyToClipboard.rawValue) }
    }

    var playSound: Bool {
        get { defaults.bool(forKey: Key.playSound.rawValue) }
        set { defaults.set(newValue, forKey: Key.playSound.rawValue) }
    }

    var savePath: String {
        get { defaults.string(forKey: Key.savePath.rawValue) ?? ("~/Pictures/ScreenGrab" as NSString).expandingTildeInPath }
        set { defaults.set(newValue, forKey: Key.savePath.rawValue) }
    }
}
