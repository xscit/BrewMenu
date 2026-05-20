import Foundation
import os

/// Modular logging: each subsystem uses a distinct category for diagnostics.
nonisolated enum Log {
    private static let subsystem: String = {
        if let id = Bundle.main.bundleIdentifier { return id }
        assertionFailure("Bundle.main.bundleIdentifier is nil — Logger subsystem will fall back to a literal and may split logs from system tools.")
        return "com.whoami.BrewMenu"
    }()

    static let core = BrewLogger(subsystem: subsystem, category: "Core")
    static let brew = BrewLogger(subsystem: subsystem, category: "Brew")
    static let upgrade = BrewLogger(subsystem: subsystem, category: "Upgrade")
    static let auth = BrewLogger(subsystem: subsystem, category: "Auth")
    static let schedule = BrewLogger(subsystem: subsystem, category: "Schedule")
}

/// Thin wrapper around os.Logger that marks all dynamic values as public
/// and mirrors notice/warning/error to ~/Library/Logs/BrewMenu.log.
nonisolated struct BrewLogger {
    private let logger: Logger
    private let category: String

    private static let fileQueue = DispatchQueue(label: "com.whoami.BrewMenu.filelog")
    private static let logURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        return logs.appendingPathComponent("BrewMenu.log")
    }()

    init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)"); append("NOTICE", message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)"); append("WARNING", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)"); append("ERROR", message)
    }

    private func append(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        Self.fileQueue.async {
            if let handle = try? FileHandle(forWritingTo: Self.logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: Self.logURL, options: .atomic)
            }
        }
    }

    private func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: Date())
    }
}
