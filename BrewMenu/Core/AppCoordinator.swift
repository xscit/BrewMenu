import AppKit
import Foundation
import Observation

/// Application coordinator: owns UI state, orchestrates business workflows,
/// and manages subsystem lifecycles. Configuration is delegated to `AppSettings`.
@Observable @MainActor
final class AppCoordinator: BrewMenuCoordinating {
    // MARK: - UI State (read-only externally; mutated via action methods)

    private(set) var status: AppStatus = .idle
    private(set) var outdatedPackages: [BrewPackage] = []
    private(set) var errorMessage: String?
    private(set) var activeUpgradePackageName: String?
    private(set) var lastCheckDate: Date?

    // MARK: - Dependencies

    let settings: AppSettings
    private let brewService: BrewServiceProtocol
    private let notificationService: NotificationServiceProtocol

    // MARK: - Subsystems (IUO: required by two-phase init — self is needed)

    private var autoScheduler: AutoScheduler!
    private var cleanupScheduler: CleanupScheduler!
    private let networkMonitor = NetworkMonitor()
    private(set) var sudoMonitor: SudoMonitor!
    private var upgradeEngine: UpgradeEngine!
    private var isCancelling = false

    // MARK: - Init

    init(
        settings: AppSettings? = nil,
        brewService: BrewServiceProtocol? = nil,
        notificationService: NotificationServiceProtocol? = nil
    ) {
        self.settings = settings ?? AppSettings()
        self.brewService = brewService ?? BrewService.shared
        let resolvedNotifications = notificationService ?? NotificationService.shared
        self.notificationService = resolvedNotifications
        if let service = resolvedNotifications as? NotificationService {
            service.settings = self.settings
        }

        // Bootstrap subsystems (requires self — hence IUO declarations above)
        autoScheduler = AutoScheduler(coordinator: self, settings: self.settings, network: networkMonitor)
        cleanupScheduler = CleanupScheduler(coordinator: self, settings: self.settings)
        sudoMonitor = SudoMonitor(
            coordinator: self,
            timeoutProvider: { [weak self] in self?.settings.authTimeout ?? 300 },
            notificationService: self.notificationService
        )
        upgradeEngine = UpgradeEngine(
            coordinator: self,
            sudoMonitor: sudoMonitor,
            brewService: self.brewService,
            notificationService: self.notificationService
        )

        Log.core.info("BrewMenu Modular Engine Started.")

        self.notificationService.requestAuthorization()
        self.notificationService.onAuthorizeActionTapped = { [weak self] in
            self?.triggerAuthorizationUI()
        }

        if self.settings.scanOnLaunch {
            Task { await check(mode: .initial) }
        }
        autoScheduler.start()
        cleanupScheduler.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }
    }

    // MARK: - BrewStatusManager Actions

    func transition(to newStatus: AppStatus) {
        status = newStatus
    }

    func setActiveUpgrade(_ packageName: String?) {
        activeUpgradePackageName = packageName
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
    }

    // MARK: - Business Actions

    /// Execute a Homebrew scan or refresh. After a successful scan, auto-upgrade
    /// if updates are available and `isAutoUpgradeEnabled` is set.
    func check(mode: ScanMode = .manual) async {
        defer { isCancelling = false }
        guard await runScan(mode: mode) else { return }

        guard mode != .refresh else { return }

        if outdatedPackages.isEmpty {
            notificationService.showNoUpdatesFound()
            return
        }

        notificationService.showUpdatesFound(packages: outdatedPackages, willAutoUpgrade: settings.isAutoUpgradeEnabled)

        if settings.isAutoUpgradeEnabled {
            await upgrade()
        }
    }

    /// Run the scan portion only. Returns `true` on success, `false` on fatal
    /// failure (so callers can short-circuit auto-upgrade etc).
    @discardableResult
    private func runScan(mode: ScanMode) async -> Bool {
        guard mode == .refresh || status == .idle || status == .outdated else { return false }

        let shouldUpdate = (mode != .refresh)
        let previousStatus = status

        status = .scanning
        errorMessage = nil

        Log.core.debug("\(mode.rawValue) scan starting...")

        let result = await brewService.getOutdatedPackages(
            shouldUpdate: shouldUpdate,
            greedyArgs: settings.greedyMode.args
        )

        switch result {
        case let .success(packages):
            outdatedPackages = packages.filter { !settings.pinnedPackages.contains($0.name) }
            status = outdatedPackages.isEmpty ? .idle : .outdated
            lastCheckDate = Date()
            Log.core.notice("\(mode.rawValue) scan completed: \(packages.count) updates.")
            return true

        case let .failure(error):
            handleScanFailure(error: error, mode: mode, previousStatus: previousStatus)
            return !error.isFatal
        }
    }

    /// Upgrade all outdated packages.
    func upgrade() async {
        await upgradeEngine.run(packages: outdatedPackages, config: settings)
    }

    /// Upgrade a single package.
    func upgrade(package: BrewPackage) async {
        await upgradeEngine.run(packages: [package], config: settings)
    }

    /// Kill active brew processes. If `shouldAbortSequence` is true, cancel the entire upgrade queue;
    /// otherwise only terminate the current package upgrade's process group and let subsequent packages continue.
    func cancel(shouldAbortSequence: Bool) {
        if shouldAbortSequence {
            isCancelling = true
            Log.core.info("User requested cancellation. Aborting all brew upgrades.")
            upgradeEngine.cancel()
        } else {
            Log.core.info("Terminating active upgrade process due to authorization cancel/timeout.")
            upgradeEngine.markCurrentPackageCancelled()
        }
        brewService.terminateAll()
    }

    /// Exclude a package from BrewMenu checks. Takes effect immediately in the menu.
    func pin(package: BrewPackage) {
        settings.pinnedPackages.insert(package.name)
        outdatedPackages.removeAll { $0.name == package.name }
        if outdatedPackages.isEmpty { status = .idle }
    }

    /// Remove a package from the exclusion list. Takes effect on the next scan.
    func unpin(packageName: String) {
        settings.pinnedPackages.remove(packageName)
    }

    /// Trigger the authorization UI via DistributedNotification.
    func triggerAuthorizationUI() {
        sudoMonitor.triggerAuthorizationUI()
    }

    /// Execute a cleanup task and record the completion date on success.
    func cleanup() async {
        let pruneArg = settings.cleanupPruneDays == 0 ? "--prune=all" : "--prune=\(settings.cleanupPruneDays)"
        Log.core.info("Running brew cleanup (\(pruneArg))...")
        let success = await brewService.cleanup(pruneDays: settings.cleanupPruneDays)
        if success {
            settings.lastCleanupDate = Date()
            Log.core.notice("Cleanup completed successfully.")
        } else {
            Log.core.warning("Cleanup finished with errors.")
        }
    }

    // MARK: - Private Helpers

    private func handleScanFailure(error: BrewError, mode: ScanMode, previousStatus: AppStatus) {
        defer { isCancelling = false }
        // User-initiated cancel: restore state silently, no notification.
        if isCancelling {
            Log.core.info("Scan cancelled by user. Restoring previous status.")
            status = (previousStatus == .updating) ? .idle : previousStatus
            return
        }
        if error.isFatal {
            // Fatal error: lock the app state, requiring the user to fix the environment
            status = .error(error)
            notificationService.showBrewNotFound()
        } else {
            // Non-fatal: roll back to the previous state
            // Special case: if previously .updating (post-upgrade refresh), force .idle to prevent stuck state
            status = (previousStatus == .updating) ? .idle : previousStatus
            notificationService.showTransientError(error: error, packageName: nil)
        }
        Log.core.error("\(mode.rawValue) scan failed: \(error.userMessage)")
    }
}
