import Foundation

/// UserDefaults storage key constants and default values.
enum DefaultsKey {
    static let checkInterval = "checkInterval"
    static let isAutoUpgradeEnabled = "isAutoUpgradeEnabled"
    static let greedyMode = "greedyMode"
    static let cleanupMode = "cleanupMode"
    static let authTimeout = "authTimeout"
    static let customCheckInterval = "customCheckInterval"

    // MARK: - Default Values

    /// Minimum allowed custom check interval in seconds (1 minute).
    static let minimumCustomIntervalSeconds = 60
    /// Maximum allowed custom check interval in seconds (7 days).
    /// Prevents pathological user input (months, years) from disabling scans.
    static let maximumCustomIntervalSeconds = 7 * 24 * 3600
    /// Default custom check interval in seconds (1 hour).
    static let defaultCustomIntervalSeconds = 3600
    /// Default authorization timeout in seconds (5 minutes).
    static let defaultAuthTimeoutSeconds = 300
}
