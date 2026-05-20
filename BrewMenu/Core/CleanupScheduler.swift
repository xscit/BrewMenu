import AppKit
import Foundation

/// Manages scheduled brew cleanup via NSBackgroundActivityScheduler.
///
/// - Primary trigger: NSBackgroundActivityScheduler — macOS decides the optimal
///   time within the configured interval, independent of the scan timer and
///   unaffected by the check interval being disabled.
/// - Fallback trigger: screen wake — compares `lastCleanupDate` against
///   `cleanupIntervalDays` to catch cases where the background activity state
///   was reset (e.g. after a system update or app reinstall).
/// - Settings changes are observed via `withObservationTracking`; the scheduler
///   re-arms automatically without any external coordination.
@MainActor
final class CleanupScheduler {
    private weak var coordinator: BrewStatusManager?
    private let settings: AppSettings
    private let clock: ClockProvider
    private let workspaceCenter: NotificationCenter
    private var backgroundScheduler: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?

    init(coordinator: BrewStatusManager,
         settings: AppSettings,
         clock: ClockProvider = SystemClock(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter)
    {
        self.coordinator = coordinator
        self.settings = settings
        self.clock = clock
        self.workspaceCenter = workspaceCenter
    }

    deinit {
        if let wakeObserver { workspaceCenter.removeObserver(wakeObserver) }
    }

    /// Begin scheduling. Safe to call once at startup.
    func start() {
        installWakeObserver()
        arm()
        checkIfNeeded()
    }

    /// Invalidate the background scheduler and stop observing.
    func stop() {
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
    }

    // MARK: - Private

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIfNeeded()
            }
        }
    }

    private func arm() {
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil

        // Re-arm when schedule or interval changes.
        withObservationTracking {
            _ = settings.cleanupSchedule
            _ = settings.cleanupIntervalDays
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.arm() }
        }

        guard settings.cleanupSchedule == .everyNDays else { return }

        let intervalDays = settings.cleanupIntervalDays
        let identifier = (Bundle.main.bundleIdentifier ?? "com.brewmenu") + ".cleanup"
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.interval = Double(intervalDays) * 86400
        scheduler.tolerance = 3600
        scheduler.qualityOfService = .background

        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self,
                      let status = coordinator?.status,
                      status == .idle || status == .outdated
                else {
                    completion(.deferred)
                    return
                }
                Log.schedule.info("CleanupScheduler: background activity fired.")
                await coordinator?.cleanup()
                completion(.finished)
            }
        }

        backgroundScheduler = scheduler
        Log.schedule.info("CleanupScheduler armed: every \(intervalDays) day(s), tolerance 1h.")
    }

    /// Fallback: run cleanup if the interval has elapsed, regardless of whether
    /// the background activity fired. Called at startup and on every screen wake.
    private func checkIfNeeded() {
        guard settings.cleanupSchedule == .everyNDays else { return }
        guard let status = coordinator?.status, status == .idle || status == .outdated else { return }
        let intervalSeconds = Double(settings.cleanupIntervalDays) * 86400
        let elapsed = clock.now.timeIntervalSince(settings.lastCleanupDate ?? .distantPast)
        guard elapsed >= intervalSeconds else { return }
        Log.schedule.info("CleanupScheduler fallback triggered (\(Int(elapsed))s elapsed).")
        Task { @MainActor in
            await coordinator?.cleanup()
        }
    }
}
