import AppKit
import Foundation
import Observation
import os

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
        self.notificationService = notificationService ?? NotificationService.shared

        // Bootstrap subsystems (requires self — hence IUO declarations above)
        self.autoScheduler = AutoScheduler(coordinator: self, settings: self.settings, network: self.networkMonitor)
        self.sudoMonitor = SudoMonitor(
            coordinator: self,
            timeoutProvider: { [weak self] in self?.settings.authTimeout ?? 300 },
            notificationService: self.notificationService
        )
        self.upgradeEngine = UpgradeEngine(
            coordinator: self,
            sudoMonitor: sudoMonitor,
            brewService: self.brewService,
            notificationService: self.notificationService
        )

        Log.core.notice("BrewMenu Modular Engine Started.")

        self.notificationService.requestAuthorization()
        self.notificationService.onAuthorizeActionTapped = { [weak self] in
            self?.triggerAuthorizationUI()
        }

        Task { await check(mode: .initial) }
        autoScheduler.start()

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
        
        // Notify user about found updates (skip for silent refreshes)
        guard mode != .refresh, !outdatedPackages.isEmpty else { return }
        notificationService.showUpdatesFound(packages: outdatedPackages)
        
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

        logScanStart(mode: mode)

        let result = await brewService.getOutdatedPackages(
            shouldUpdate: shouldUpdate,
            greedyArgs: settings.greedyMode.args
        )

        switch result {
        case .success(let packages):
            outdatedPackages = packages
            status = packages.isEmpty ? .idle : .outdated
            lastCheckDate = Date()
            Log.core.notice("\(mode.rawValue) scan completed: \(packages.count) updates.")
            return true

        case .failure(let error):
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

    /// Kill all app-spawned brew processes (upgrade loop, scan, cleanup).
    /// Safe to call at any time — no-op if nothing is running.
    func cancel() {
        isCancelling = true
        Log.core.notice("User requested cancellation. Terminating all brew processes.")
        upgradeEngine.cancel()
        brewService.terminateAll()
    }

    /// Trigger the authorization UI via DistributedNotification.
    func triggerAuthorizationUI() {
        sudoMonitor.triggerAuthorizationUI()
    }

    /// Execute a cleanup task.
    func cleanup() async {
        _ = await brewService.cleanup(mode: settings.cleanupMode)
    }

    // MARK: - Private Helpers

    private func logScanStart(mode: ScanMode) {
        let icons: [ScanMode: String] = [.initial: "🚀", .automatic: "⏰", .manual: "🔍", .refresh: "🔄"]
        Log.core.debug("\(icons[mode] ?? "") \(mode.rawValue) scan starting...")
    }

    private func handleScanFailure(error: BrewError, mode: ScanMode, previousStatus: AppStatus) {
        defer { isCancelling = false }
        // User-initiated cancel: restore state silently, no notification.
        if isCancelling {
            Log.core.notice("Scan cancelled by user. Restoring previous status.")
            status = (previousStatus == .updating) ? .idle : previousStatus
            return
        }
        if error.isFatal {
            // Fatal error: lock the app state, requiring the user to fix the environment
            status = .error(error)
        } else {
            // Non-fatal: roll back to the previous state
            // Special case: if previously .updating (post-upgrade refresh), force .idle to prevent stuck state
            status = (previousStatus == .updating) ? .idle : previousStatus
            // Auto-scans silently skip network failures — the next scheduled cycle will retry.
            if !(mode == .automatic && error.isNetworkError) {
                notificationService.showTransientError(error: error, packageName: nil)
            }
        }
        Log.core.error("\(mode.rawValue) scan failed: \(error.userMessage)")
    }
}
