import Darwin
import Foundation

/// Monitors DistributedNotification signals from the AskPass helper to coordinate
/// authorization prompts during upgrades.
@MainActor
final class SudoMonitor {
    private weak var coordinator: BrewStatusManager?
    private let notificationService: NotificationServiceProtocol
    private let timeoutProvider: () -> Int
    private let ppidProvider: (Int32) -> Int32?
    private var activePIDs = Set<Int32>()
    private var notifiedPIDs = Set<Int32>()
    private var currentSessionPID: Int32?
    private var observers: [ObserverWrapper] = []
    private var timeoutTask: Task<Void, Never>?

    /// Wrapper that auto-removes the observer from DistributedNotificationCenter on dealloc.
    private final class ObserverWrapper {
        let observer: NSObjectProtocol
        init(_ observer: NSObjectProtocol) {
            self.observer = observer
        }

        deinit { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    init(
        coordinator: BrewStatusManager,
        timeoutProvider: @escaping () -> Int = { 300 },
        notificationService: NotificationServiceProtocol? = nil,
        ppidProvider: @escaping (Int32) -> Int32? = SudoMonitor.sysctlPPID
    ) {
        self.coordinator = coordinator
        self.timeoutProvider = timeoutProvider
        self.notificationService = notificationService ?? NotificationService.shared
        self.ppidProvider = ppidProvider
    }

    /// Register the PID of a new upgrade session.
    func registerSession(pid: Int32) {
        currentSessionPID = pid
        notifiedPIDs.removeAll()
    }

    /// Start monitoring (listen for distributed notifications).
    func start() {
        stop()

        let center = DistributedNotificationCenter.default()

        // Listen for helper-started signal
        let startedObs = center.addObserver(forName: BrewMenuNotification.helperStarted, object: nil, queue: .main) { [weak self] note in
            guard let self, let pidStr = note.object as? String, let pid = Int32(pidStr) else { return }

            Task { @MainActor in
                // Lineage check: verify the helper is a descendant of the current brew process
                // Chain: Helper(Z) -> sudo(Y) -> brew(X)
                if let ppid = self.ppidProvider(pid), let gpid = self.ppidProvider(ppid) {
                    guard gpid == self.currentSessionPID else { return }
                } else {
                    return
                }

                self.activePIDs.insert(pid)
                await self.handleMonitorResult()
            }
        }

        // Listen for helper-finished signal
        let finishedObs = center.addObserver(forName: BrewMenuNotification.helperFinished, object: nil, queue: .main) { [weak self] note in
            guard let self, let pidStr = note.object as? String, let pid = Int32(pidStr) else { return }

            Task { @MainActor in
                // No lineage re-check needed — the process may have already exited
                self.activePIDs.remove(pid)
                if let userInfo = note.userInfo, userInfo["status"] as? String == "cancelled" {
                    self.coordinator?.cancel(shouldAbortSequence: false)
                } else {
                    await self.handleMonitorResult()
                }
            }
        }

        observers = [ObserverWrapper(startedObs), ObserverWrapper(finishedObs)]
    }

    /// Stop monitoring and clear all state.
    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        observers.removeAll()
        activePIDs.removeAll()
        notifiedPIDs.removeAll()
        currentSessionPID = nil
    }

    /// Broadcast a trigger to all waiting AskPass helpers via DistributedNotification.
    func triggerAuthorizationUI() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let name = coordinator?.activeUpgradePackageName ?? ""
        Log.auth.notice("User triggered Sudo AskPass UI for [\(name)].")

        for pid in activePIDs {
            DistributedNotificationCenter.default().postNotificationName(
                BrewMenuNotification.triggerName(for: pid),
                object: nil,
                userInfo: ["package_info": name],
                deliverImmediately: true
            )
        }
    }

    private func handleMonitorResult() async {
        guard let coordinator else { return }

        // New PIDs detected — notify user
        let newPIDs = activePIDs.subtracting(notifiedPIDs)
        if !newPIDs.isEmpty {
            let isRetry = !notifiedPIDs.isEmpty
            coordinator.transition(to: .authorizing)

            let name = coordinator.activeUpgradePackageName ?? "a package"
            if isRetry {
                Log.auth.info("Sudo authorization retry requested for [\(name)].")
            } else {
                Log.auth.info("Sudo authorization required for [\(name)].")
            }

            notificationService.showAuthRequired(packageNames: [name], isRetry: isRetry)

            notifiedPIDs.formUnion(newPIDs)
            startTimeoutTask()
        }

        // All helpers finished — return to updating state
        if activePIDs.isEmpty, coordinator.status == .authorizing {
            timeoutTask?.cancel()
            timeoutTask = nil
            coordinator.transition(to: .updating)
        }
    }

    /// Broadcast a cancel signal to all waiting AskPass helpers.
    func cancelAuthorizationUI() {
        let name = coordinator?.activeUpgradePackageName ?? "a package"
        let seconds = timeoutProvider()
        Log.auth.notice("Sudo authorization timed out (exceeded \(seconds)s) for [\(name)]. Cancelling AskPass helpers.")

        notificationService.showAuthTimeout(packageName: name)

        for pid in activePIDs {
            DistributedNotificationCenter.default().postNotificationName(
                BrewMenuNotification.cancelName(for: pid),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }

        coordinator?.cancel(shouldAbortSequence: false)
    }

    private func startTimeoutTask() {
        timeoutTask?.cancel()
        let seconds = timeoutProvider()
        Log.auth.info("Authorization timeout countdown started: \(seconds) seconds.")
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancelAuthorizationUI()
            } catch {
                // Task cancelled
            }
        }
    }

    // MARK: - Testing

    /// Directly invoke the helperStarted handling logic without going through
    /// DistributedNotificationCenter. Use this in unit tests to avoid depending
    /// on the system notification daemon (which is unreliable in XCTest hosts).
    @MainActor
    func simulateHelperStarted(pid: Int32) async {
        if let ppid = ppidProvider(pid), let gpid = ppidProvider(ppid) {
            guard gpid == currentSessionPID else { return }
        } else {
            return
        }
        activePIDs.insert(pid)
        await handleMonitorResult()
    }

    /// Directly invoke the helperFinished handling logic without going through
    /// DistributedNotificationCenter. Use this in unit tests.
    @MainActor
    func simulateHelperFinished(pid: Int32, isCancelled: Bool = false) async {
        activePIDs.remove(pid)
        if isCancelled {
            coordinator?.cancel(shouldAbortSequence: false)
        } else {
            await handleMonitorResult()
        }
    }

    // MARK: - Helpers

    /// Resolve parent PID via sysctl (non-blocking, no subprocess).
    nonisolated static func sysctlPPID(pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else {
            Log.auth.warning("sysctl failed for PID \(pid)")
            return nil
        }

        return info.kp_eproc.e_ppid
    }
}
