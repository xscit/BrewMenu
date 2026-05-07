import Foundation
import Observation
import ServiceManagement
import os

/// Centralized, observable configuration store.
///
/// All persistent settings live here, each with a `didSet` that writes through
/// to the injected `SettingsStore`. Observers (e.g., `AutoScheduler`) react to
/// schedule-affecting changes via `withObservationTracking`, so no explicit
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

    var cleanupMode: CleanupMode {
        didSet { store.set(cleanupMode.rawValue, forKey: DefaultsKey.cleanupMode) }
    }

    // MARK: - Authorization

    var authTimeout: Int {
        didSet { store.set(authTimeout, forKey: DefaultsKey.authTimeout) }
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
        self.checkInterval = CheckInterval(rawValue: savedInterval) ?? .oneHour

        var customInterval = store.integer(forKey: DefaultsKey.customCheckInterval)
        if customInterval == 0 { customInterval = DefaultsKey.defaultCustomIntervalSeconds }
        self.customCheckInterval = customInterval

        self.isAutoUpgradeEnabled = store.bool(forKey: DefaultsKey.isAutoUpgradeEnabled)

        let savedGreedy = store.string(forKey: DefaultsKey.greedyMode) ?? GreedyMode.disabled.rawValue
        self.greedyMode = GreedyMode(rawValue: savedGreedy) ?? .disabled

        let savedCleanup = store.string(forKey: DefaultsKey.cleanupMode) ?? CleanupMode.disabled.rawValue
        self.cleanupMode = CleanupMode(rawValue: savedCleanup) ?? .disabled

        self.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        var savedTimeout = store.integer(forKey: DefaultsKey.authTimeout)
        if savedTimeout == 0 { savedTimeout = DefaultsKey.defaultAuthTimeoutSeconds }
        self.authTimeout = savedTimeout
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
            Log.core.error("LaunchAtLogin sync failed: \(error.localizedDescription)")
            isLaunchAtLoginEnabled = (service.status == .enabled)
        }
    }
}
