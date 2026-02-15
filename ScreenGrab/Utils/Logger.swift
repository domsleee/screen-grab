import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    static func from(_ string: String) -> LogLevel {
        switch string.lowercased() {
        case "debug": return .debug
        case "warn", "warning": return .warn
        case "error": return .error
        default: return .info
        }
    }
}

final class Logger {
    static let shared = Logger()

    private var logFileURL: URL?
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.screengrab.logger", qos: .utility)

    private var isEnabled: Bool { AppSettings.shared.loggingEnabled }
    private var minLevel: LogLevel { LogLevel.from(AppSettings.shared.logLevel) }

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        setupLogFile()
    }

    private func setupLogFile() {
        guard isEnabled else { return }

        // Create log directory in ~/Library/Logs/ScreenGrab
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenGrab")

        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            print("[ScreenGrab Logger] Failed to create log directory: \(error)")
            return
        }

        // Log file with date
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let filename = "screengrab-\(today.string(from: Date())).log"
        logFileURL = logsDir.appendingPathComponent(filename)

        // Create file if needed and open for appending
        if let url = logFileURL {
            if !FileManager.default.fileExists(atPath: url.path) {
                if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                    print("[ScreenGrab Logger] Failed to create log file at \(url.path)")
                    return
                }
            }
            do {
                fileHandle = try FileHandle(forWritingTo: url)
                fileHandle?.seekToEndOfFile()
            } catch {
                print("[ScreenGrab Logger] Failed to open log file: \(error)")
            }
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    private func log(_ level: LogLevel, _ message: String, file: String, line: Int) {
        guard isEnabled, level.order >= minLevel.order else { return }

        // Lazy init log file if needed
        if fileHandle == nil {
            setupLogFile()
        }

        let timestamp = dateFormatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let logLine = "[\(timestamp)] [\(level.rawValue)] [\(filename):\(line)] \(message)\n"

        queue.async { [weak self] in
            if let data = logLine.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }

    func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(.debug, message, file: file, line: line)
    }

    func info(_ message: String, file: String = #file, line: Int = #line) {
        log(.info, message, file: file, line: line)
    }

    func warn(_ message: String, file: String = #file, line: Int = #line) {
        log(.warn, message, file: file, line: line)
    }

    func error(_ message: String, file: String = #file, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }
}

// Convenience global functions
func logDebug(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.debug(message, file: file, line: line)
}

func logInfo(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.info(message, file: file, line: line)
}

func logWarn(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.warn(message, file: file, line: line)
}

func logError(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.error(message, file: file, line: line)
}
