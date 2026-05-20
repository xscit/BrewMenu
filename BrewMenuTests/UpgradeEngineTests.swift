@testable import BrewMenu
import Foundation
import Testing

@Suite("UpgradeEngine")
@MainActor
struct UpgradeEngineTests {
    private func makeEngine(
        brewService: MockBrewService,
        notificationService: MockNotificationService,
        coordinator: MockCoordinator
    ) -> UpgradeEngine {
        UpgradeEngine(
            coordinator: coordinator,
            sudoMonitor: SudoMonitor(coordinator: coordinator),
            brewService: brewService,
            notificationService: notificationService
        )
    }

    // MARK: 基础行为

    /// 空包列表不应触发状态转换，run() 应立即返回
    @Test func emptyPackagesIsNoOp() async {
        let coordinator = MockCoordinator()
        let runner = MockBrewCommandRunner()
        let service = BrewService(
            runner: runner,
            authService: AuthorizationService(bundle: .main),
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        )
        let engine = UpgradeEngine(coordinator: coordinator, sudoMonitor: SudoMonitor(coordinator: coordinator), brewService: service)
        await engine.run(packages: [], config: MockConfig())
        #expect(coordinator.transitionHistory.isEmpty)
        #expect(runner.executedCommands.isEmpty)
    }

    /// 正常升级开始时必须进入 .updating 状态，驱动菜单栏 UI 显示进度
    @Test func runTransitionsToUpdating() async {
        let coordinator = MockCoordinator()
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]), exitCode: 1)
        let service = BrewService(
            runner: runner,
            authService: AuthorizationService(bundle: .main),
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        )
        let engine = UpgradeEngine(coordinator: coordinator, sudoMonitor: SudoMonitor(coordinator: coordinator), brewService: service)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        #expect(coordinator.transitionHistory.contains(.updating))
    }

    /// 外部已升级的包跳过升级并触发 refresh
    @Test func externallyUpgradedPackageSkipsUpgradeAndRefreshes() async {
        let coordinator = MockCoordinator()
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0) // pre-check exits 0 → 外部已升级
        let service = BrewService(
            runner: runner,
            authService: AuthorizationService(bundle: .main),
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        )
        let engine = UpgradeEngine(coordinator: coordinator, sudoMonitor: SudoMonitor(coordinator: coordinator), brewService: service)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        #expect(coordinator.checkModes.contains(.refresh))
        #expect(coordinator.errorMessage == nil)
    }

    /// cancel() 在 isRunning=false 时应是空操作，不应改变任何状态
    @Test func cancelBeforeRunIsNoOp() {
        let coordinator = MockCoordinator()
        let engine = makeEngine(brewService: MockBrewService(), notificationService: MockNotificationService(), coordinator: coordinator)
        engine.cancel()
        #expect(coordinator.transitionHistory.isEmpty)
    }

    /// run() 完成后 isRunning 必须重置，保证引擎可复用
    @Test func engineIsReusableAcrossRuns() async {
        let brewSvc = MockBrewService()
        brewSvc.enqueueStillOutdated(false) // first run: wget 外部已升级
        let coordinator = MockCoordinator()
        let engine = makeEngine(brewService: brewSvc, notificationService: MockNotificationService(), coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        let firstCount = coordinator.transitionHistory.count

        brewSvc.enqueueStillOutdated(false) // second run: curl 外部已升级
        await engine.run(packages: [makePackage("curl")], config: MockConfig())
        #expect(coordinator.transitionHistory.count > firstCount)
    }

    // MARK: 升级成功

    /// 升级成功后发送结果通知
    @Test func upgradeSuccessNotifiesSummary() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)"); return
        }
        #expect(notifSvc.upgradeResultCalls[0].requestedNames == ["wget"])
    }

    /// 多包：一个外部升级，一个真实升级 → externalSuccessNames 正确
    @Test func multiplePackagesOneExternalOneReal() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(false) // wget: 外部已升级
        brewSvc.enqueueStillOutdated(true) // curl: 仍需升级
        brewSvc.enqueueUpgrade(.success(true))

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget"), makePackage("curl")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)"); return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.externalSuccessNames == ["wget"])
        #expect(call.requestedNames == ["wget", "curl"])
    }

    // MARK: userCancelled

    /// userCancelled 进入 skippedNames，overallSuccess 不变
    @Test func userCancelledDuringUpgradeIsSkipped() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.userCancelled))

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)"); return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.skippedNames == ["wget"])
        #expect(call.success == true)
    }

    /// 一包 userCancelled，一包成功 → upgraded(1) + external(0) == requested(2) - skipped(1) → success=true
    @Test func oneSkippedOneSuccessIsSuccess() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.userCancelled))
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget"), makePackage("curl")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)"); return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.skippedNames == ["wget"])
        #expect(call.success == true)
    }

    // MARK: 认证失败

    /// authenticationFailed → overallSuccess=false + errorMessage 不为空
    @Test func authFailedSetsErrorMessageAndOverallFailure() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: MockConfig())

        #expect(coordinator.errorMessage != nil)
        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)"); return
        }
        #expect(notifSvc.upgradeResultCalls[0].success == false)
    }

    /// 包升级后仍 outdated → failedErrors 包含该包的错误原因
    @Test func authFailedPackageStillOutdatedReflectedInSummary() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))
        coordinator.outdatedQueue = [[makePackage("wget")]] // refresh 后 wget 仍 outdated

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: MockConfig())

        #expect(notifSvc.transientErrorCalls.isEmpty)
        #expect(notifSvc.upgradeResultCalls.first?.failedErrors["wget"] != nil)
    }

    /// 包升级后不在 outdated（brew 实际成功但报错）→ failedErrors 中不含该包
    @Test func authFailedPackageNoLongerOutdatedNotInFailedErrors() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))
        // refresh 返回空列表 → brew 实际成功

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: MockConfig())

        #expect(notifSvc.transientErrorCalls.isEmpty)
        #expect(notifSvc.upgradeResultCalls.first?.failedErrors["wget"] == nil)
    }

    // MARK: 网络错误

    /// 批量升级全部断网时，只发一条 summary 通知，不逐包发 transientError
    @Test func networkFailureDuringBatchUpgradeProducesOnlySummary() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        for _ in 0 ..< 3 {
            brewSvc.enqueueStillOutdated(true)
            brewSvc.enqueueUpgrade(.failure(.networkUnavailable))
        }
        coordinator.outdatedQueue = [[makePackage("a"), makePackage("b"), makePackage("c")]]

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("a"), makePackage("b"), makePackage("c")], config: MockConfig())

        #expect(notifSvc.transientErrorCalls.isEmpty, "网络错误不应逐包发送 transientError 通知")
        guard let call = notifSvc.upgradeResultCalls.first else {
            Issue.record("Expected exactly 1 summary notification"); return
        }
        #expect(call.failedErrors["a"] != nil)
        #expect(call.failedErrors["b"] != nil)
        #expect(call.failedErrors["c"] != nil)
    }

    // MARK: 取消

    /// A 升成功后用户在 B 期间取消，B 和 C 均应显示为 Skipped 而非 Failed
    @Test func cancelMidUpgradeShowsUnprocessedPackagesAsSkipped() async {
        // brew service：第一次 upgrade 成功后触发取消，第二次调用不会到达
        final class CancelInjectingBrewService: BrewServiceProtocol, @unchecked Sendable {
            var onFirstUpgrade: (() -> Void)?
            private var upgradeCallCount = 0

            func getOutdatedPackages(shouldUpdate _: Bool, greedyArgs _: [String]) async -> Result<[BrewPackage], BrewError> {
                .success([])
            }

            func checkIfPackageIsStillOutdated(name _: String, greedyArgs _: [String]) async -> Bool {
                true
            }

            func upgrade(packages _: [BrewPackage], greedyArgs _: [String], authTimeout _: Int, onPID _: (@Sendable (Int32) -> Void)?) async -> Result<Bool, BrewError> {
                upgradeCallCount += 1
                if upgradeCallCount == 1 {
                    onFirstUpgrade?()
                    return .success(true)
                }
                return .failure(.commandFailed("killed by SIGINT"))
            }

            func terminateAll() {}
            func cleanup(pruneDays _: Int) async -> Bool {
                true
            }
        }

        let brewSvc = CancelInjectingBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        coordinator.outdatedQueue = [[makePackage("pkg-b"), makePackage("pkg-c")]]

        let engine = UpgradeEngine(
            coordinator: coordinator,
            sudoMonitor: SudoMonitor(coordinator: coordinator),
            brewService: brewSvc,
            notificationService: notifSvc
        )
        brewSvc.onFirstUpgrade = { engine.cancel() }

        await engine.run(
            packages: [makePackage("pkg-a"), makePackage("pkg-b"), makePackage("pkg-c")],
            config: MockConfig()
        )

        guard let call = notifSvc.upgradeResultCalls.first else {
            Issue.record("Expected upgrade result notification"); return
        }
        let upgradedNames = Set(call.upgraded.map(\.name))
        let externalNames = Set(call.externalSuccessNames)
        let skippedSet = Set(call.skippedNames)
        let failedNames = call.requestedNames.filter {
            !upgradedNames.contains($0) && !externalNames.contains($0) && !skippedSet.contains($0)
        }
        #expect(failedNames.isEmpty, "取消的包应为 Skipped，不应为 Failed。实际 failed: \(failedNames)")
        #expect(skippedSet.contains("pkg-b"))
        #expect(skippedSet.contains("pkg-c"))
    }

    /// 取消升级且无任何包完成 → 不发任何通知
    @Test func cancelWithNothingDoneIssilent() async {
        final class ImmediateCancelBrewService: BrewServiceProtocol, @unchecked Sendable {
            var onFirstUpgrade: (() -> Void)?
            func getOutdatedPackages(shouldUpdate _: Bool, greedyArgs _: [String]) async -> Result<[BrewPackage], BrewError> {
                .success([])
            }

            func checkIfPackageIsStillOutdated(name _: String, greedyArgs _: [String]) async -> Bool {
                true
            }

            func upgrade(packages _: [BrewPackage], greedyArgs _: [String], authTimeout _: Int, onPID _: (@Sendable (Int32) -> Void)?) async -> Result<Bool, BrewError> {
                onFirstUpgrade?()
                return .failure(.commandFailed("killed"))
            }

            func terminateAll() {}
            func cleanup(pruneDays _: Int) async -> Bool {
                true
            }
        }

        let brewSvc = ImmediateCancelBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        // refresh 后 wget 仍 outdated → calculateUpgraded 返回空 → 不触发通知
        coordinator.outdatedQueue = [[makePackage("wget")]]

        let engine = UpgradeEngine(
            coordinator: coordinator,
            sudoMonitor: SudoMonitor(coordinator: coordinator),
            brewService: brewSvc,
            notificationService: notifSvc
        )
        brewSvc.onFirstUpgrade = { engine.cancel() }

        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        #expect(notifSvc.upgradeResultCalls.isEmpty, "취消且无包完成时不应发通知")
    }

    // MARK: 自动清理

    /// cleanupSchedule == .afterUpgrade → 升级完成后调用 cleanup
    @Test func autoCleanupRunsWhenEnabled() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))

        struct CleanupConfig: BrewConfiguration, Sendable {
            var greedyMode: GreedyMode = .disabled
            var cleanupSchedule: CleanupSchedule = .afterUpgrade
            var authTimeout: Int = 300
        }

        await makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
            .run(packages: [makePackage("wget")], config: CleanupConfig())

        #expect(coordinator.cleanupCallCount == 1)
    }
}
