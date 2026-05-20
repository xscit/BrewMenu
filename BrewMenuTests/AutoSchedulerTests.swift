import AppKit
@testable import BrewMenu
import Testing

@Suite("AutoScheduler")
@MainActor
struct AutoSchedulerTests {
    private struct OfflineNetwork: NetworkConnectivityProvider { var isConnected: Bool {
        false
    } }
    private struct OnlineNetwork: NetworkConnectivityProvider { var isConnected: Bool {
        true
    } }

    private final class MutableClock: ClockProvider {
        var now: Date = .init(timeIntervalSinceReferenceDate: 0)
    }

    private func makeScheduler(
        coordinator: MockCoordinator,
        network: NetworkConnectivityProvider = OnlineNetwork(),
        clock: ClockProvider? = nil,
        workspaceCenter: NotificationCenter = NotificationCenter()
    ) -> AutoScheduler {
        let settings = AppSettings(store: MockSettingsStore())
        return AutoScheduler(
            coordinator: coordinator,
            settings: settings,
            network: network,
            clock: clock ?? SystemClock(),
            workspaceCenter: workspaceCenter
        )
    }

    // MARK: fire

    /// 离线时跳过 check
    @Test func fireSkipsWhenOffline() async {
        let coordinator = MockCoordinator()
        makeScheduler(coordinator: coordinator, network: OfflineNetwork()).fire()
        await Task.yield()
        #expect(coordinator.checkModes.isEmpty)
    }

    /// 在线时触发 check(mode:.automatic)
    @Test func fireTriggersCheckWhenOnline() async {
        let coordinator = MockCoordinator()
        makeScheduler(coordinator: coordinator).fire()
        await Task.yield(); await Task.yield()
        #expect(coordinator.checkModes.contains(.automatic))
    }

    // MARK: handleWake

    /// 超期立即 fire
    @Test func handleWakeFiresImmediatelyWhenOverdue() async {
        let coordinator = MockCoordinator()
        let clock = MutableClock()
        let scheduler = makeScheduler(coordinator: coordinator, clock: clock)

        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.fire() // lastFireDate = t0

        clock.now = Date(timeIntervalSinceReferenceDate: 7200) // t0 + 2h，超过默认 1h 间隔
        scheduler.handleWake()
        await Task.yield(); await Task.yield()

        #expect(coordinator.checkModes.filter { $0 == .automatic }.count >= 2)
    }

    /// 未超期只 arm，不立即 fire
    @Test func handleWakeArmOnlyWhenNotOverdue() async {
        let coordinator = MockCoordinator()
        let clock = MutableClock()
        let scheduler = makeScheduler(coordinator: coordinator, clock: clock)

        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.fire()
        await Task.yield(); await Task.yield()
        let baseCount = coordinator.checkModes.count

        clock.now = Date(timeIntervalSinceReferenceDate: 60) // 仅 60s，远未超期
        scheduler.handleWake()
        await Task.yield(); await Task.yield()

        #expect(coordinator.checkModes.count == baseCount)
    }

    /// lastFireDate 和 lastCheckDate 均为 nil → 只 arm，不 fire
    @Test func handleWakeNoLastFireDateArmOnly() async {
        let coordinator = MockCoordinator()
        makeScheduler(coordinator: coordinator).handleWake()
        await Task.yield(); await Task.yield()
        #expect(coordinator.checkModes.isEmpty)
    }

    /// lastFireDate 为 nil 但 lastCheckDate 超期 → 立即 fire
    @Test func handleWakeFiresWhenLastCheckDateOverdue() async {
        let coordinator = MockCoordinator()
        let clock = MutableClock()
        clock.now = Date(timeIntervalSinceReferenceDate: 7200)
        let scheduler = makeScheduler(coordinator: coordinator, clock: clock)
        coordinator.lastCheckDate = clock.now.addingTimeInterval(-3700)

        scheduler.handleWake()
        await Task.yield(); await Task.yield()
        #expect(coordinator.checkModes == [.automatic])
    }

    /// interval==.off → handleWake 无操作
    @Test func handleWakeSkipsWhenIntervalIsOff() async {
        let coordinator = MockCoordinator()
        let store = MockSettingsStore()
        store.set(CheckInterval.off.rawValue, forKey: DefaultsKey.checkInterval)
        let settings = AppSettings(store: store)
        let scheduler = AutoScheduler(coordinator: coordinator, settings: settings, network: OnlineNetwork())
        scheduler.handleWake()
        await Task.yield()
        #expect(coordinator.checkModes.isEmpty)
    }

    // MARK: start / stop

    /// stop() 破棄タイマー，stop 后 yield 也不触发 check
    @Test func stopAfterStartPreventsTimerFire() async {
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator)
        scheduler.start()
        scheduler.stop()
        await Task.yield(); await Task.yield()
        #expect(coordinator.checkModes.count == 0)
    }

    // MARK: 系统通知

    /// screensDidSleep → 定时器被销毁，后续 check 计数不变
    @Test func sleepNotificationInvalidatesTimer() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator, workspaceCenter: center)
        scheduler.start()

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await Task.yield(); await Task.yield()

        #expect(coordinator.checkModes.count == 0)
    }

    /// screensDidWake → handleWake() 被调用；lastFireDate=nil 时只 arm，不触发 check
    @Test func wakeNotificationCallsHandleWake() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator, workspaceCenter: center)
        scheduler.start()

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await Task.yield(); await Task.yield()

        #expect(coordinator.checkModes.isEmpty)
    }

    /// screensDidWake 且 lastFireDate 已超期 → 立即 fire()
    @Test func wakeNotificationFiresWhenOverdue() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let clock = MutableClock()
        let scheduler = makeScheduler(coordinator: coordinator, clock: clock, workspaceCenter: center)

        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.start()
        scheduler.fire()
        await Task.yield(); await Task.yield()
        let baseCount = coordinator.checkModes.count

        clock.now = Date(timeIntervalSinceReferenceDate: 100_000) // 远超间隔
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms，等待多层异步

        #expect(coordinator.checkModes.count > baseCount)
    }
}
