@testable import BrewMenu
import Foundation
import Testing

@Suite("AppCoordinator")
@MainActor
struct AppCoordinatorTests {
    /// 注入 MockBrewService 和 MockNotificationService，并排空初始 check(mode:.initial) 产生的 Task。
    /// 必须在 init 之后入队测试数据，因为 init 里的 Task { await check(mode: .initial) }
    /// 会消费队列中的第一个元素。
    private func makeCoordinator(
        brewService: MockBrewService? = nil,
        notifSvc: MockNotificationService? = nil,
        settings: AppSettings? = nil
    ) async -> AppCoordinator {
        let appSettings = settings ?? AppSettings(store: MockSettingsStore())
        let coordinator = AppCoordinator(
            settings: appSettings,
            brewService: brewService ?? MockBrewService(),
            notificationService: notifSvc ?? MockNotificationService()
        )
        // Drain the initial scan task launched in init
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        return coordinator
    }

    // MARK: check(mode:)

    /// 扫描返回包列表时 status 变为 .outdated，发出 updatesFound 通知
    @Test func checkWithPackagesTransitionsToOutdated() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.success([makePackage("wget")]))
        await coordinator.check(mode: .manual)

        #expect(coordinator.status == .outdated)
        #expect(coordinator.outdatedPackages.count == 1)
        #expect(notifSvc.updatesFoundCalls.count == 1)
    }

    /// 扫描返回空列表时 status 变为 .idle，不发通知
    @Test func checkWithNoPackagesTransitionsToIdle() async {
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(notifSvc: notifSvc)
        await coordinator.check(mode: .manual)
        #expect(coordinator.status == .idle)
        #expect(notifSvc.updatesFoundCalls.isEmpty)
    }

    /// 手动扫描无更新时发 noUpdatesFound 通知（初始扫描已发一次，共 2 次）
    @Test func manualScanNoUpdatesNotifiesUser() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.success([]))
        await coordinator.check(mode: .manual)

        #expect(notifSvc.noUpdatesFoundCalls == 2)
        #expect(notifSvc.updatesFoundCalls.isEmpty)
    }

    /// 自动扫描无更新时也发 noUpdatesFound 通知（初始扫描已发一次，共 2 次）
    @Test func automaticScanNoUpdatesNotifiesUser() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.success([]))
        await coordinator.check(mode: .automatic)

        #expect(notifSvc.noUpdatesFoundCalls == 2)
        #expect(notifSvc.updatesFoundCalls.isEmpty)
    }

    /// refresh 模式找到包时不发 updatesFound 通知
    @Test func checkRefreshModeDoesNotNotify() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        let noUpdatesCountBefore = notifSvc.noUpdatesFoundCalls
        brewSvc.enqueueOutdated(.success([makePackage("wget")]))
        await coordinator.check(mode: .refresh)

        #expect(notifSvc.updatesFoundCalls.isEmpty)
        #expect(notifSvc.noUpdatesFoundCalls == noUpdatesCountBefore, "refresh 模式不应触发任何通知")
    }

    /// 自动升级开启时，check 后触发 upgrade()（verifies upgradeResult notification fired）
    @Test func checkAutoUpgradeEnabledTriggersUpgrade() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let store = MockSettingsStore()
        store.set(true, forKey: DefaultsKey.isAutoUpgradeEnabled)
        let settings = AppSettings(store: store)

        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc, settings: settings)

        brewSvc.enqueueOutdated(.success([makePackage("wget")]))
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))
        await coordinator.check(mode: .manual)

        #expect(notifSvc.upgradeResultCalls.count == 1)
    }

    /// status が .updating のとき runScan は即返し、status は変化しない
    @Test func checkWhileUpdatingIsSkipped() async {
        let coordinator = await makeCoordinator()
        coordinator.transition(to: .updating)
        await coordinator.check(mode: .manual)
        #expect(coordinator.status == .updating)
    }

    // MARK: handleScanFailure

    /// 致命错误时 status 变为 .error(_)
    @Test func fatalScanErrorSetsErrorStatus() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.failure(.brewNotFound))
        await coordinator.check(mode: .manual)

        guard case .error = coordinator.status else {
            Issue.record("Expected .error status, got \(coordinator.status)"); return
        }
        #expect(notifSvc.brewNotFoundCalls == 1)
    }

    /// 非致命手动扫描错误触发 transientError 通知
    @Test func nonFatalManualScanErrorShowsTransientError() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.failure(.networkUnavailable))
        await coordinator.check(mode: .manual)

        #expect(notifSvc.transientErrorCalls.count == 1)
    }

    /// 非致命自动扫描 + 网络错误 → 静默，不发 transientError
    @Test func nonFatalAutoScanNetworkErrorNotifiesUser() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.failure(.networkUnavailable))
        await coordinator.check(mode: .automatic)

        #expect(notifSvc.transientErrorCalls.count == 1)
        #expect(notifSvc.transientErrorCalls[0].0 == .networkUnavailable)
    }

    /// refresh + 网络错误 → 发 transientError（网络在扫描途中断开，非启动时未就绪）
    @Test func nonFatalRefreshNetworkErrorNotifiesUser() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        brewSvc.enqueueOutdated(.failure(.networkUnavailable))
        await coordinator.check(mode: .refresh)

        #expect(notifSvc.transientErrorCalls.count == 1)
        #expect(notifSvc.transientErrorCalls[0].0 == .networkUnavailable)
    }

    /// 非致命错误后 status 回滚到扫描前的状态（.idle → .idle）
    @Test func nonFatalErrorRestoresPreviousStatus() async {
        let brewSvc = MockBrewService()
        let coordinator = await makeCoordinator(brewService: brewSvc)

        brewSvc.enqueueOutdated(.failure(.networkUnavailable))
        await coordinator.check(mode: .manual)

        #expect(coordinator.status == .idle)
    }

    // MARK: cancel

    /// cancel() 调用 brewService.terminateAll
    @Test func cancelCallsTerminateAll() async {
        let brewSvc = MockBrewService()
        let coordinator = await makeCoordinator(brewService: brewSvc)
        coordinator.cancel()
        #expect(brewSvc.terminateCallCount >= 1)
    }

    // MARK: pin / unpin

    /// pin 立即将包从 outdatedPackages 移除
    @Test func pinRemovesPackageFromOutdated() async {
        let brewSvc = MockBrewService()
        let coordinator = await makeCoordinator(brewService: brewSvc)

        brewSvc.enqueueOutdated(.success([makePackage("wget"), makePackage("curl")]))
        await coordinator.check(mode: .manual)
        #expect(coordinator.outdatedPackages.count == 2)

        coordinator.pin(package: makePackage("wget"))
        #expect(coordinator.outdatedPackages.count == 1)
        #expect(coordinator.outdatedPackages.first?.name == "curl")
    }

    /// pin 最后一个包时 status → .idle
    @Test func pinLastPackageTransitionsToIdle() async {
        let brewSvc = MockBrewService()
        let coordinator = await makeCoordinator(brewService: brewSvc)

        brewSvc.enqueueOutdated(.success([makePackage("wget")]))
        await coordinator.check(mode: .manual)
        #expect(coordinator.status == .outdated)

        coordinator.pin(package: makePackage("wget"))
        #expect(coordinator.status == .idle)
    }

    /// pin 的包名写入 settings.pinnedPackages
    @Test func pinPersistsToSettings() async {
        let coordinator = await makeCoordinator()
        coordinator.pin(package: makePackage("wget"))
        #expect(coordinator.settings.pinnedPackages.contains("wget"))
    }

    /// unpin 从 settings.pinnedPackages 移除包名
    @Test func unpinRemovesFromSettings() async {
        let coordinator = await makeCoordinator()
        coordinator.pin(package: makePackage("wget"))
        coordinator.unpin(packageName: "wget")
        #expect(!coordinator.settings.pinnedPackages.contains("wget"))
    }

    // MARK: pinnedPackages 过滤

    /// runScan 成功时，已 pin 的包不出现在 outdatedPackages
    @Test func pinnedPackagesFilteredFromScanResults() async {
        let brewSvc = MockBrewService()
        let store = MockSettingsStore()
        store.set(["wget"], forKey: DefaultsKey.pinnedPackages)
        let settings = AppSettings(store: store)

        let coordinator = await makeCoordinator(brewService: brewSvc, settings: settings)

        brewSvc.enqueueOutdated(.success([makePackage("wget"), makePackage("curl")]))
        await coordinator.check(mode: .manual)

        #expect(coordinator.outdatedPackages.map(\.name) == ["curl"])
    }

    // MARK: cleanup

    /// cleanup() 调用 brewService.cleanup 并在成功时设置 lastCleanupDate
    @Test func cleanupSetsLastCleanupDateOnSuccess() async {
        let brewSvc = MockBrewService()
        let coordinator = await makeCoordinator(brewService: brewSvc)

        let before = Date()
        await coordinator.cleanup()
        let after = Date()

        #expect(brewSvc.cleanupCallCount == 1)
        let date = coordinator.settings.lastCleanupDate
        #expect(date != nil)
        if let date {
            #expect(date >= before && date <= after)
        }
    }

    // MARK: upgrade(package:)

    // upgrade(package:) 触发 upgradeEngine，完成后发 upgradeResult 通知
    @Test func upgradePackageCompletesAndNotifies() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))
        let coordinator = await makeCoordinator(brewService: brewSvc, notifSvc: notifSvc)

        await coordinator.upgrade(package: makePackage("wget"))

        #expect(notifSvc.upgradeResultCalls.count == 1)
        #expect(notifSvc.upgradeResultCalls[0].requestedNames == ["wget"])
    }
}
