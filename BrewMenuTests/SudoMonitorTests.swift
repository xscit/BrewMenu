import AppKit
@testable import BrewMenu
import Testing

@Suite("SudoMonitor")
@MainActor
struct SudoMonitorTests {
    private func makeMonitor(
        coordinator: MockCoordinator,
        notifSvc: MockNotificationService? = nil,
        timeoutSeconds: Int = 300,
        ppidProvider: @escaping (Int32) -> Int32? = { _ in nil }
    ) -> SudoMonitor {
        SudoMonitor(
            coordinator: coordinator,
            timeoutProvider: { timeoutSeconds },
            notificationService: notifSvc ?? MockNotificationService(),
            ppidProvider: ppidProvider
        )
    }

    /// pid→ppid→gpid，gpid 匹配 currentSessionPID → 通知发出，status → .authorizing
    @Test func lineageMatchAllowsSession() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(
            coordinator: coordinator,
            ppidProvider: { pid in
                switch pid {
                case 10: 20 // Helper's parent = sudo
                case 20: 30 // sudo's parent = brew
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.transitionHistory.contains(.authorizing))
    }

    /// gpid 不匹配 currentSessionPID → 被拒绝，status 不变
    @Test func lineageMismatchBlocksSession() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: { pid in
            switch pid {
            case 10: 20
            case 20: 99 // gpid=99 ≠ currentSession=30
            default: nil
            }
        })
        monitor.registerSession(pid: 30)
        monitor.start()

        DistributedNotificationCenter.default().postNotificationName(
            BrewMenuNotification.helperStarted, object: "10", userInfo: nil, deliverImmediately: true
        )
        await Task.yield(); await Task.yield(); await Task.yield()

        #expect(!coordinator.transitionHistory.contains(.authorizing))
    }

    /// ppidProvider 返回 nil（sysctl 失败）→ 拒绝
    @Test func ppidLookupFailureBlocksSession() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: { _ in nil })
        monitor.registerSession(pid: 30)
        monitor.start()

        DistributedNotificationCenter.default().postNotificationName(
            BrewMenuNotification.helperStarted, object: "10", userInfo: nil, deliverImmediately: true
        )
        await Task.yield(); await Task.yield(); await Task.yield()

        #expect(!coordinator.transitionHistory.contains(.authorizing))
    }

    /// stop 后再次 stop 不崩溃
    @Test func stopClearsObserversAndPIDs() {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator)
        monitor.start()
        monitor.stop()
        monitor.stop()
    }

    /// timeout 极短时，授权超时通知被触发
    @Test func timeoutCancelsActivePIDs() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        let monitor = SudoMonitor(
            coordinator: coordinator,
            timeoutProvider: { 0 },
            notificationService: notifSvc,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms，等待 timeout Task 完成
        #expect(notifSvc.authTimeoutCalls > 0)
    }

    /// triggerAuthorizationUI 在有 activePID 时不崩溃
    @Test func triggerAuthorizationUIWithActiveSession() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(
            coordinator: coordinator,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.transitionHistory.contains(.authorizing))
        monitor.triggerAuthorizationUI()
    }

    /// Helper finished → activePIDs 清空，status 从 .authorizing → .updating
    @Test func helperFinishedTransitionsBackToUpdating() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(
            coordinator: coordinator,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.status == .authorizing)

        await monitor.simulateHelperFinished(pid: 10)
        #expect(coordinator.transitionHistory.last == .updating)
    }

    /// 第二个 Helper 启动时，以 isRetry=true 发出通知
    @Test func secondHelperTriggersRetryNotification() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        let monitor = makeMonitor(
            coordinator: coordinator,
            notifSvc: notifSvc,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                case 11: 21
                case 21: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        await monitor.simulateHelperStarted(pid: 11)
        #expect(notifSvc.authRequiredCalls >= 2)
    }

    /// simulateHelperStarted 时 gpid 不匹配 → 忽略，status 不变
    @Test func simulateHelperStartedGPIDMismatchIsIgnored() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: { pid in
            switch pid {
            case 10: 20
            case 20: 99 // gpid=99 ≠ currentSession=30
            default: nil
            }
        })
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.transitionHistory.isEmpty)
    }

    /// sysctlPPID 对当前进程返回非 nil 的有效 PPID
    @Test func sysctlPPIDReturnsNonNilForCurrentProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ppid = SudoMonitor.sysctlPPID(pid: pid)
        #expect(ppid != nil)
        #expect((ppid ?? 0) > 0)
    }

    /// Dialogue cancellation via helper Finished triggers unified coordinator cancel
    @Test func helperFinishedWithCancelledStatusTriggersCancel() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(
            coordinator: coordinator,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        await monitor.simulateHelperFinished(pid: 10, isCancelled: true)
        #expect(coordinator.cancelCallCount > 0)
        #expect(coordinator.lastCancelShouldAbortSequence == false)
    }

    /// Timeout in cancelAuthorizationUI triggers unified coordinator cancel
    @Test func authorizationTimeoutTriggersCancel() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(
            coordinator: coordinator,
            timeoutSeconds: 0,
            ppidProvider: { pid in
                switch pid {
                case 10: 20
                case 20: 30
                default: nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)

        // Wait for the timeout task to complete and invoke cancelAuthorizationUI()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(coordinator.cancelCallCount > 0)
        #expect(coordinator.lastCancelShouldAbortSequence == false)
    }
}
