import Foundation
import AppKit
import Observation
import os

// MARK: - Injectable protocols

protocol NetworkConnectivityProvider {
    var isConnected: Bool { get }
}

nonisolated protocol ClockProvider {
    var now: Date { get }
}

nonisolated struct SystemClock: ClockProvider {
    var now: Date { Date() }
}

/// Background scheduler: manages the auto-scan timer lifecycle.
///
/// - Timer is tied to screen state: invalidated on `screensDidSleepNotification`,
///   rebuilt on `screensDidWakeNotification`. PowerNap dark wakes never fire the
///   wake notification, so the timer stays dead and no scan runs.
/// - On screen wake, `lastFireDate` is compared against the configured interval;
///   an overdue scan fires immediately before the timer is re-armed.
/// - `fire()` checks network connectivity before starting a scan. If offline,
///   the scan is silently skipped and `lastFireDate` is not updated, so the
///   next cycle or wake will retry. Callers can later gate on `network.isExpensive`
///   or `network.isConstrained` for hotspot / Low Data Mode support.
/// - Settings changes are observed via `withObservationTracking`; the timer
///   re-arms automatically without any external coordination.
@MainActor
final class AutoScheduler {
    private weak var coordinator: BrewStatusManager?
    private let settings: AppSettings
    private let networkProvider: NetworkConnectivityProvider
    private let clock: ClockProvider
    private let workspaceCenter: NotificationCenter
    private var timer: Timer?
    private(set) var lastFireDate: Date?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(coordinator: BrewStatusManager,
         settings: AppSettings,
         network: NetworkConnectivityProvider,
         clock: ClockProvider = SystemClock(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.coordinator = coordinator
        self.settings = settings
        self.networkProvider = network
        self.clock = clock
        self.workspaceCenter = workspaceCenter
    }

    deinit {
        if let sleepObserver { workspaceCenter.removeObserver(sleepObserver) }
        if let wakeObserver { workspaceCenter.removeObserver(wakeObserver) }
    }

    /// Begin scheduling. Observes settings changes and system wake events so
    /// the caller only needs to invoke this once at startup.
    func start() {
        installWakeObserverIfNeeded()
        armTimer()
    }

    /// Cancel the timer and stop observing.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func installWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
        // screensDidWakeNotification only fires on real user-visible wakes, not PowerNap dark wakes.
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }
    }

    func handleWake() {
        guard settings.checkInterval != .off else { return }
        guard let last = lastFireDate else {
            armTimer()
            return
        }
        let interval = settings.currentIntervalSeconds
        let elapsed = clock.now.timeIntervalSince(last)
        if elapsed >= interval {
            Log.schedule.info("Screen wake detected with overdue scan (\(Int(elapsed))s elapsed). Firing immediately.")
            fire()
        }
        armTimer()
    }

    /// Configure the timer and subscribe to settings mutations that would
    /// require a re-arm. When observation fires, we simply re-arm — the new
    /// snapshot is read inside `armTimer`.
    private func armTimer() {
        timer?.invalidate()
        timer = nil

        guard let coordinator else { return }

        // Only track schedule-affecting settings. Tracking coordinator.status would
        // re-arm on every status transition (scanning → idle → outdated…), causing
        // redundant timer resets and log spam.
        let snapshot: (interval: CheckInterval, seconds: Double) =
            withObservationTracking {
                (settings.checkInterval, settings.currentIntervalSeconds)
            } onChange: { [weak self] in
                // onChange delivers willSet; re-arm asynchronously after the change lands.
                // Rebind as a `let` before the Task to satisfy Swift 6's rule against
                // capturing `weak var` references in concurrently-executing code.
                guard let self else { return }
                Task { @MainActor in
                    self.armTimer()
                }
            }

        // Status check outside the tracking block — error state suspends scheduling
        // but does not need to be observed (fire() is a no-op when status == .error).
        if case .error = coordinator.status {
            Log.schedule.notice("Automatic scan suspended due to system error.")
            return
        }

        if snapshot.interval == .off {
            Log.schedule.info("Automatic scan disabled by user configuration.")
            return
        }

        let seconds = snapshot.seconds
        Log.schedule.info("Scheduling scan every \(seconds) seconds.")
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fire()
            }
        }
    }

    func fire() {
        guard networkProvider.isConnected else {
            Log.schedule.info("Skipping automatic scan: no network connection.")
            return
        }
        lastFireDate = clock.now
        Task { @MainActor in
            await coordinator?.check(mode: .automatic)
        }
    }
}
