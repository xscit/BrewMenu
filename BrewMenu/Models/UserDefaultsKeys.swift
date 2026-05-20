/// UserDefaults storage key constants and default values.
enum DefaultsKey {
    static let checkInterval = "checkInterval"
    static let isAutoUpgradeEnabled = "isAutoUpgradeEnabled"
    static let greedyMode = "greedyMode"
    static let cleanupSchedule = "cleanupSchedule"
    static let cleanupIntervalDays = "cleanupIntervalDays"
    static let cleanupPruneDays = "cleanupPruneDays"
    static let lastCleanupDate = "lastCleanupDate"
    static let authTimeout = "authTimeout"
    static let customCheckInterval = "customCheckInterval"
    static let pinnedPackages = "pinnedPackages"
    static let scanOnLaunch = "scanOnLaunch"

    // MARK: - Notification Toggles

    static let notifyOnScanResults = "notifyOnScanResults"
    static let notifyOnUpgradeResult = "notifyOnUpgradeResult"
    static let notifyOnAuthRequired = "notifyOnAuthRequired"
    static let notifyOnErrors = "notifyOnErrors"

    // MARK: - Default Values

    /// Minimum allowed custom check interval in seconds (5 minutes).
    /// Shorter intervals offer no practical benefit and add unnecessary shell overhead.
    static let minimumCustomIntervalSeconds = 5 * 60
    /// Maximum allowed custom check interval in seconds (30 days).
    static let maximumCustomIntervalSeconds = 30 * 24 * 3600
    /// Default custom check interval in seconds (1 hour).
    static let defaultCustomIntervalSeconds = 3600
    /// Minimum authorization timeout in seconds (1 minute).
    static let minimumAuthTimeoutSeconds = 60
    /// Maximum authorization timeout in seconds (60 minutes).
    /// A password prompt waiting longer than this is effectively abandoned.
    static let maximumAuthTimeoutSeconds = 60 * 60
    /// Default authorization timeout in seconds (5 minutes).
    static let defaultAuthTimeoutSeconds = 300
    /// Default scheduled cleanup interval in days (7 days).
    static let defaultCleanupIntervalDays = 7
    /// Minimum scheduled cleanup interval in days.
    static let minimumCleanupIntervalDays = 1
    /// Maximum scheduled cleanup interval in days (90 days).
    static let maximumCleanupIntervalDays = 90
    /// Maximum prune age in days (0 = --prune=all).
    static let maximumCleanupPruneDays = 365
}
