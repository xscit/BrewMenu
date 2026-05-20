import Foundation
import Observation
import ServiceManagement

/// Centralized, observable configuration store.
///
/// All persistent settings live here, each with a `didSet` that writes through
/// to the injected `SettingsStore`. Observers (e.g., `AutoScheduler`, `CleanupScheduler`)
/// react to schedule-affecting changes via `withObservationTracking`, so no explicit
/// callback wiring is required.
@Observable @MainActor
final class AppSettings: BrewConfiguration {
    // MARK: - Schedule

    var checkInterval: CheckInterval {
        didSet {
            store.set(checkInterval.rawValue, forKey: DefaultsKey.checkInterval)
        }
    }

    var customCheckInterval: Int {
        didSet {
            let clamped = min(
                max(customCheckInterval, DefaultsKey.minimumCustomIntervalSeconds),
                DefaultsKey.maximumCustomIntervalSeconds
            )
            if clamped != customCheckInterval {
                customCheckInterval = clamped
                return
            }
            store.set(customCheckInterval, forKey: DefaultsKey.customCheckInterval)
        }
    }

    /// Effective check interval in seconds.
    var currentIntervalSeconds: Double {
        checkInterval == .custom ? Double(customCheckInterval) : Double(checkInterval.rawValue)
    }

    // MARK: - Upgrade Behavior

    var isAutoUpgradeEnabled: Bool {
        didSet { store.set(isAutoUpgradeEnabled, forKey: DefaultsKey.isAutoUpgradeEnabled) }
    }

    var greedyMode: GreedyMode {
        didSet { store.set(greedyMode.rawValue, forKey: DefaultsKey.greedyMode) }
    }

    // MARK: - Cleanup

    var cleanupSchedule: CleanupSchedule {
        didSet {
            store.set(cleanupSchedule.rawValue, forKey: DefaultsKey.cleanupSchedule)
            Log.core.info("Cleanup schedule changed: \(cleanupSchedule.rawValue)")
        }
    }

    var cleanupIntervalDays: Int {
        didSet {
            let clamped = min(
                max(cleanupIntervalDays, DefaultsKey.minimumCleanupIntervalDays),
                DefaultsKey.maximumCleanupIntervalDays
            )
            if clamped != cleanupIntervalDays {
                cleanupIntervalDays = clamped
                return
            }
            store.set(cleanupIntervalDays, forKey: DefaultsKey.cleanupIntervalDays)
            Log.core.info("Cleanup interval changed: every \(cleanupIntervalDays) day(s)")
        }
    }

    /// Cache files older than this many days are removed. 0 means `--prune=all`.
    var cleanupPruneDays: Int {
        didSet {
            let clamped = min(max(cleanupPruneDays, 0), DefaultsKey.maximumCleanupPruneDays)
            if clamped != cleanupPruneDays {
                cleanupPruneDays = clamped
                return
            }
            store.set(cleanupPruneDays, forKey: DefaultsKey.cleanupPruneDays)
            let pruneArg = cleanupPruneDays == 0 ? "--prune=all" : "--prune=\(cleanupPruneDays)"
            Log.core.info("Cleanup prune age changed: \(pruneArg)")
        }
    }

    var lastCleanupDate: Date? {
        didSet { store.set(lastCleanupDate, forKey: DefaultsKey.lastCleanupDate) }
    }

    // MARK: - Exclusions

    var pinnedPackages: Set<String> {
        didSet { store.set(Array(pinnedPackages), forKey: DefaultsKey.pinnedPackages) }
    }

    // MARK: - Authorization

    var authTimeout: Int {
        didSet { store.set(authTimeout, forKey: DefaultsKey.authTimeout) }
    }

    var scanOnLaunch: Bool {
        didSet { store.set(scanOnLaunch, forKey: DefaultsKey.scanOnLaunch) }
    }

    // MARK: - Notifications

    var notifyOnScanResults: Bool {
        didSet { store.set(notifyOnScanResults, forKey: DefaultsKey.notifyOnScanResults) }
    }

    var notifyOnUpgradeResult: Bool {
        didSet { store.set(notifyOnUpgradeResult, forKey: DefaultsKey.notifyOnUpgradeResult) }
    }

    var notifyOnAuthRequired: Bool {
        didSet { store.set(notifyOnAuthRequired, forKey: DefaultsKey.notifyOnAuthRequired) }
    }

    var notifyOnErrors: Bool {
        didSet { store.set(notifyOnErrors, forKey: DefaultsKey.notifyOnErrors) }
    }

    // MARK: - System Integration

    var isLaunchAtLoginEnabled: Bool = false {
        didSet {
            guard oldValue != isLaunchAtLoginEnabled, !isSyncing else { return }
            syncLaunchAtLogin()
        }
    }

    // MARK: - Private

    private let store: SettingsStore
    /// Prevents recursive `didSet` when rolling back `isLaunchAtLoginEnabled` on error.
    private var isSyncing = false

    // MARK: - Init

    init(store: SettingsStore = UserDefaults.standard) {
        self.store = store

        // Read persisted values without triggering didSet
        let savedInterval = store.object(forKey: DefaultsKey.checkInterval) as? Int
            ?? CheckInterval.oneHour.rawValue
        checkInterval = CheckInterval(rawValue: savedInterval) ?? .oneHour

        var customInterval = store.integer(forKey: DefaultsKey.customCheckInterval)
        if customInterval == 0 { customInterval = DefaultsKey.defaultCustomIntervalSeconds }
        customCheckInterval = customInterval

        isAutoUpgradeEnabled = store.bool(forKey: DefaultsKey.isAutoUpgradeEnabled)

        let savedScanOnLaunch = store.object(forKey: DefaultsKey.scanOnLaunch) as? Bool ?? true
        scanOnLaunch = savedScanOnLaunch

        let savedGreedy = store.string(forKey: DefaultsKey.greedyMode) ?? GreedyMode.disabled.rawValue
        greedyMode = GreedyMode(rawValue: savedGreedy) ?? .disabled

        let savedCleanup = store.string(forKey: DefaultsKey.cleanupSchedule) ?? CleanupSchedule.disabled.rawValue
        cleanupSchedule = CleanupSchedule(rawValue: savedCleanup) ?? .disabled

        var savedCleanupInterval = store.integer(forKey: DefaultsKey.cleanupIntervalDays)
        if savedCleanupInterval == 0 { savedCleanupInterval = DefaultsKey.defaultCleanupIntervalDays }
        cleanupIntervalDays = savedCleanupInterval

        cleanupPruneDays = store.integer(forKey: DefaultsKey.cleanupPruneDays)
        lastCleanupDate = store.object(forKey: DefaultsKey.lastCleanupDate) as? Date

        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        var savedTimeout = store.integer(forKey: DefaultsKey.authTimeout)
        if savedTimeout == 0 { savedTimeout = DefaultsKey.defaultAuthTimeoutSeconds }
        authTimeout = savedTimeout

        let savedPinned = store.object(forKey: DefaultsKey.pinnedPackages) as? [String] ?? []
        pinnedPackages = Set(savedPinned)

        notifyOnScanResults = store.object(forKey: DefaultsKey.notifyOnScanResults) as? Bool ?? true
        notifyOnUpgradeResult = store.object(forKey: DefaultsKey.notifyOnUpgradeResult) as? Bool ?? true
        notifyOnAuthRequired = store.object(forKey: DefaultsKey.notifyOnAuthRequired) as? Bool ?? true
        notifyOnErrors = store.object(forKey: DefaultsKey.notifyOnErrors) as? Bool ?? true
    }

    // MARK: - Private Helpers

    private func syncLaunchAtLogin() {
        isSyncing = true
        defer { isSyncing = false }

        let service = SMAppService.mainApp
        do {
            if isLaunchAtLoginEnabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            Log.core.warning("LaunchAtLogin sync failed: \(error.localizedDescription)")
            isLaunchAtLoginEnabled = (service.status == .enabled)
        }
    }
}
