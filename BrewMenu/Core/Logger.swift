import Foundation
import os

/// Modular logging: each subsystem uses a distinct category for diagnostics.
nonisolated enum Log {
    private static let subsystem: String = {
        if let id = Bundle.main.bundleIdentifier { return id }
        assertionFailure("Bundle.main.bundleIdentifier is nil — Logger subsystem will fall back to a literal and may split logs from system tools.")
        return "com.whoami.BrewMenu"
    }()

    static let core     = Logger(subsystem: subsystem, category: "Core")
    static let brew     = Logger(subsystem: subsystem, category: "Brew")
    static let upgrade  = Logger(subsystem: subsystem, category: "Upgrade")
    static let auth     = Logger(subsystem: subsystem, category: "Auth")
    static let schedule = Logger(subsystem: subsystem, category: "Schedule")
}
