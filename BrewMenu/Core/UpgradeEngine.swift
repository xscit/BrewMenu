/// Upgrade engine: manages sequential upgrade queue, cancellation logic, and result aggregation.
@MainActor
final class UpgradeEngine {
    private weak var coordinator: BrewStatusManager?
    private let sudoMonitor: SudoMonitor
    private let brewService: BrewServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private var isRunning = false
    private var isCancelled = false
    private var isCurrentPackageCancelled = false

    init(
        coordinator: BrewStatusManager,
        sudoMonitor: SudoMonitor,
        brewService: BrewServiceProtocol? = nil,
        notificationService: NotificationServiceProtocol? = nil
    ) {
        self.coordinator = coordinator
        self.sudoMonitor = sudoMonitor
        self.brewService = brewService ?? BrewService.shared
        self.notificationService = notificationService ?? NotificationService.shared
    }

    /// Abort any in-progress upgrade: stops the loop and cleans up sudo monitoring.
    /// Callers are responsible for calling brewService.terminateAll() to kill processes.
    func cancel() {
        guard isRunning else { return }
        isCancelled = true
        Log.upgrade.notice("Upgrade cancelled. Stopping sudo monitor.")
        sudoMonitor.stop()
    }

    func markCurrentPackageCancelled() {
        isCurrentPackageCancelled = true
    }

    /// Execute the main upgrade flow.
    func run(packages: [BrewPackage], config: BrewConfiguration) async {
        guard !packages.isEmpty, let coordinator, !isRunning else { return }
        isRunning = true
        isCancelled = false
        defer { isRunning = false }

        let greedyArgs = config.greedyMode.args
        let authTimeout = config.authTimeout

        let beforeList = packages
        coordinator.transition(to: .updating)
        coordinator.setErrorMessage(nil)

        var overallSuccess = true
        var skippedNames: [String] = []
        var externalSuccessNames: [String] = []
        var failedErrors: [String: BrewError] = [:]
        Log.upgrade.info("Starting sequential upgrade for \(packages.count) packages.")

        sudoMonitor.start()

        for pkg in packages {
            guard !isCancelled else { break }
            isCurrentPackageCancelled = false
            coordinator.setActiveUpgrade(pkg.name)

            // Pre-check: skip packages already upgraded externally (e.g., via Terminal)
            if await !brewService.checkIfPackageIsStillOutdated(name: pkg.name, greedyArgs: greedyArgs) {
                Log.upgrade.info("[\(pkg.name)] is already up to date. Skipping.")
                externalSuccessNames.append(pkg.name)
                continue
            }

            Log.upgrade.info("Upgrading [\(pkg.name)]...")
            let result = await brewService.upgrade(packages: [pkg], greedyArgs: greedyArgs, authTimeout: authTimeout, onPID: { pid in
                Task { @MainActor in
                    self.sudoMonitor.registerSession(pid: pid)
                }
            })

            switch result {
            case .success:
                Log.upgrade.notice("[\(pkg.name)] upgraded successfully.")
            case let .failure(error):
                if isCurrentPackageCancelled || error.isUserCancelled {
                    Log.upgrade.notice("Upgrade skipped (cancelled/timeout) during [\(pkg.name)].")
                    skippedNames.append(pkg.name)
                } else {
                    overallSuccess = false
                    coordinator.setErrorMessage(error.userMessage)
                    if let detail = error.technicalDetail {
                        Log.upgrade.error("[\(pkg.name)] failed: \(detail)")
                    } else {
                        Log.upgrade.error("[\(pkg.name)] failed: \(error.userMessage)")
                    }
                    failedErrors[pkg.name] = error
                }
            }
        }

        sudoMonitor.stop()
        coordinator.setActiveUpgrade(nil)

        if isCancelled {
            Log.upgrade.info("Upgrade cancelled. Notifying about any completed packages.")
            await coordinator.check(mode: .refresh)
            let upgraded = calculateUpgraded(before: beforeList, after: coordinator.outdatedPackages)
            if !upgraded.isEmpty || !externalSuccessNames.isEmpty {
                // Any package not upgraded or externally synced was interrupted by
                // cancellation — report as skipped, not failed.
                let doneNames = Set(upgraded.map(\.name) + externalSuccessNames)
                let cancelledSkippedNames = beforeList.map(\.name).filter { !doneNames.contains($0) }
                notificationService.showUpgradeResult(
                    upgraded: upgraded,
                    success: false,
                    requestedNames: beforeList.map(\.name),
                    skippedNames: cancelledSkippedNames,
                    externalSuccessNames: externalSuccessNames,
                    failedErrors: [:]
                )
            }
            return
        }

        await finishUpgrade(
            beforeList: beforeList,
            overallSuccess: overallSuccess,
            skippedNames: skippedNames,
            externalSuccessNames: externalSuccessNames,
            failedErrors: failedErrors,
            config: config
        )
    }

    private func finishUpgrade(beforeList: [BrewPackage], overallSuccess: Bool, skippedNames: [String], externalSuccessNames: [String], failedErrors: [String: BrewError], config: BrewConfiguration) async {
        guard let coordinator else { return }

        let savedError = coordinator.errorMessage

        if config.cleanupSchedule == .afterUpgrade {
            Log.upgrade.info("Auto-cleanup after upgrade. Running brew cleanup...")
            await coordinator.cleanup()
        }

        await coordinator.check(mode: .refresh)

        // Merge error messages so the user sees both upgrade and refresh errors
        if let saved = savedError, let current = coordinator.errorMessage, saved != current {
            coordinator.setErrorMessage("\(saved)\n\(current)")
        } else if savedError != nil && coordinator.errorMessage == nil {
            coordinator.setErrorMessage(savedError)
        }

        // Exclude skipped packages: a userCancelled package may not appear in
        // outdatedPackages after refresh (e.g. external upgrade), but it was never
        // actually upgraded by us and must not count toward the success tally.
        let skippedNamesSet = Set(skippedNames)
        let upgraded = calculateUpgraded(before: beforeList, after: coordinator.outdatedPackages)
            .filter { !skippedNamesSet.contains($0.name) }

        // Only surface errors for packages still outdated after refresh — a non-zero exit code
        // with the package actually installed means brew succeeded despite warnings.
        let afterNames = Set(coordinator.outdatedPackages.map(\.name))
        let relevantFailedMessages = failedErrors
            .filter { afterNames.contains($0.key) }
            .mapValues { $0.userMessage }

        if !upgraded.isEmpty || overallSuccess == false || !externalSuccessNames.isEmpty || !skippedNames.isEmpty {
            notificationService.showUpgradeResult(
                upgraded: upgraded,
                success: overallSuccess && (upgraded.count + externalSuccessNames.count) == (beforeList.count - skippedNames.count),
                requestedNames: beforeList.map(\.name),
                skippedNames: skippedNames,
                externalSuccessNames: externalSuccessNames,
                failedErrors: relevantFailedMessages
            )
        }
    }

    private func calculateUpgraded(before: [BrewPackage], after: [BrewPackage]) -> [BrewPackage] {
        let afterNames = Set(after.map(\.name))
        return before.filter { !afterNames.contains($0.name) }
    }
}
