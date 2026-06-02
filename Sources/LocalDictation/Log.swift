import Foundation
import os

/// Tee-ing logger. Every line goes to:
///   1. stderr (visible when running from a terminal)
///   2. ~/Library/Logs/local-dictation.log (file we can read back later)
///   3. Apple unified logging (`log stream --predicate 'subsystem == "com.norfeldt.local-dictation"'`)
enum Log {
    private static let subsystem = "com.norfeldt.local-dictation"
    private static let osLog = Logger(subsystem: subsystem, category: "app")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileHandle: FileHandle? = {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("local-dictation.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static let logFilePath: String =
        (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/local-dictation.log").path) ?? "<unavailable>"

    enum Level: String { case debug = "DEBUG", info = "INFO ", warn = "WARN ", error = "ERROR" }

    static func info(_ message: @autoclosure () -> String, _ tag: String = "app")  { write(.info,  tag, message()) }
    static func warn(_ message: @autoclosure () -> String, _ tag: String = "app")  { write(.warn,  tag, message()) }
    static func error(_ message: @autoclosure () -> String, _ tag: String = "app") { write(.error, tag, message()) }
    static func debug(_ message: @autoclosure () -> String, _ tag: String = "app") { write(.debug, tag, message()) }

    private static func write(_ level: Level, _ tag: String, _ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let line = "\(stamp) \(level.rawValue) [\(tag)] \(message)\n"

        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        if let fh = fileHandle, let data = line.data(using: .utf8) {
            try? fh.write(contentsOf: data)
        }

        switch level {
        case .debug: osLog.debug("\(tag, privacy: .public): \(message, privacy: .public)")
        case .info:  osLog.info("\(tag, privacy: .public): \(message, privacy: .public)")
        case .warn:  osLog.warning("\(tag, privacy: .public): \(message, privacy: .public)")
        case .error: osLog.error("\(tag, privacy: .public): \(message, privacy: .public)")
        }
    }

    /// Captures uncaught Obj-C exceptions and POSIX signals so a crash
    /// still leaves a breadcrumb in the file log. Call once at startup.
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Log.error("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "<no reason>")\nStack:\n\(exception.callStackSymbols.joined(separator: "\n"))", "crash")
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE] {
            signal(sig) { signum in
                let line = "FATAL signal \(signum)\n"
                FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
                // Restore default handler and re-raise so the system still crashes.
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }
}
