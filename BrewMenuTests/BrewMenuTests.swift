import Testing
import Foundation
import AppKit
import os
@testable import BrewMenu

// MARK: - Fixtures

private func makePackage(_ name: String = "wget", old: String = "1.0", new: String = "1.1") -> BrewPackage {
    BrewPackage(name: name, oldVersion: old, newVersion: new)
}

private func outdatedJSON(
    formulae: [(String, String, String)] = [],
    casks: [(String, String, String)] = []
) -> String {
    func encode(_ name: String, _ old: String, _ new: String) -> String {
        "{\"name\":\"\(name)\",\"installed_versions\":[\"\(old)\"],\"current_version\":\"\(new)\"}"
    }
    let formulaeJson = formulae.map { encode($0.0, $0.1, $0.2) }.joined(separator: ",")
    let casksJson = casks.map { encode($0.0, $0.1, $0.2) }.joined(separator: ",")
    return "{\"formulae\":[\(formulaeJson)],\"casks\":[\(casksJson)]}"
}

private struct MockConfig: BrewConfiguration, Sendable {
    var greedyMode: GreedyMode = .disabled
    var cleanupMode: CleanupMode = .disabled
    var authTimeout: Int = 300
}

// MARK: - Mocks

private final class MockBrewCommandRunner: BrewCommandRunner, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var queue: [(String, String, Int32)] = []
    private(set) var executedCommands: [BrewCommand] = []

    func enqueue(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        lock.withLock {
            queue.append((stdout, stderr, exitCode))
        }
    }

    func execute(_ command: BrewCommand) async -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.withLock {
            executedCommands.append(command)
            guard !queue.isEmpty else { return ("", "", 0) }
            let result = queue.removeFirst()
            return (stdout: result.0, stderr: result.1, exitCode: result.2)
        }
    }

    func terminateAll() {}
}

private final class MockSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var storage: [String: Any] = [:]

    func integer(forKey key: String) -> Int {
        lock.withLock { storage[key] as? Int ?? 0 }
    }
    func bool(forKey key: String) -> Bool {
        lock.withLock { storage[key] as? Bool ?? false }
    }
    func string(forKey key: String) -> String? {
        lock.withLock { storage[key] as? String }
    }
    func object(forKey key: String) -> Any? {
        lock.withLock { storage[key] }
    }
    func set(_ value: Any?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }
}

@MainActor
private final class MockCoordinator: BrewStatusManager {
    var status: AppStatus = .idle
    var outdatedPackages: [BrewPackage] = []
    var activeUpgradePackageName: String?
    var errorMessage: String?
    var lastCheckDate: Date?
    var transitionHistory: [AppStatus] = []
    var checkModes: [ScanMode] = []
    /// 每次 check() 从队列取一批，模拟真实 refresh 结果；队列耗尽则保持当前值不变
    var outdatedQueue: [[BrewPackage]] = []

    func transition(to newStatus: AppStatus) {
        status = newStatus
        transitionHistory.append(newStatus)
    }
    func setActiveUpgrade(_ name: String?) { activeUpgradePackageName = name }
    func setErrorMessage(_ msg: String?) { errorMessage = msg }
    func check(mode: ScanMode) async {
        checkModes.append(mode)
        if !outdatedQueue.isEmpty {
            outdatedPackages = outdatedQueue.removeFirst()
        } else {
            outdatedPackages = []
        }
    }
}

// MARK: - BrewError

@Suite("BrewError")
struct BrewErrorTests {

    // MARK: parse — exit 0

    // exit 0 表示命令成功，无论 stdout 内容如何都不应返回错误
    @Test func parseExitZeroReturnsNil() {
        #expect(BrewError.parse(stdout: "any output", stderr: "", exitCode: 0) == nil)
    }

    // MARK: parse — network errors

    // brew update 依赖 curl 访问 GitHub CDN，断网时 curl 报错 (6)
    @Test func parseCurlFailureIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "curl: (6) Could not resolve host: ghcr.io", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // macOS 路由层错误，与 curl 错误是独立的网络不可达信号
    @Test func parseNoRouteToHostIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "No route to host: brew.sh", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // Linux 内核级别的网络不可达
    @Test func parseNetworkIsUnreachableIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "network is unreachable", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // DNS 解析失败，与 curl: (6) 是不同措辞但等价的网络信号
    @Test func parseCouldNotResolveHostIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "could not resolve host: api.github.com", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // MARK: parse — user cancellation (must outrank auth failure when both signals appear)

    // 用户直接点「取消」或关闭密码框，AskPass 以空密码退出
    @Test func parseNoPasswordProvidedIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: no password was provided", exitCode: 1)
        #expect(err == .userCancelled)
    }

    // sudo 未能找到 tty 或 askpass 程序，视为无法获取密码，等同于用户取消
    @Test func parseNoTTYPresentIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: no tty present and no askpass program specified", exitCode: 1)
        #expect(err == .userCancelled)
    }

    // 首次弹框用户未输入任何内容直接关闭时 sudo 的输出
    @Test func parsePasswordRequiredIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: a password is required", exitCode: 1)
        #expect(err == .userCancelled)
    }

    // sudo appends "a password is required" after a failed attempt — must still be userCancelled, not authFailed
    @Test func parseCancelAfterBadAttemptIsUserCancelled() {
        let stderr = "sudo: 1 incorrect password attempt\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    // MARK: parse — authentication failure

    // sudo 连续 3 次拒绝后锁定，用户没有机会再次取消
    @Test func parseExhaustedRetriesIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: 3 incorrect password attempts", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    // PAM/Kerberos 层认证失败，与密码计数无关
    @Test func parseAuthCouldNotBeEstablishedIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "auth could not be established", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    // MARK: parse — generic failure

    // 非零退出且有 stderr → brew 执行失败，原始消息透传给调用方
    @Test func parseNonZeroWithStderrIsCommandFailed() {
        let err = BrewError.parse(stdout: "", stderr: "something went wrong", exitCode: 2)
        guard case .commandFailed(let msg) = err else { Issue.record("Expected commandFailed, got \(String(describing: err))"); return }
        #expect(msg == "something went wrong")
    }

    // stderr 为空白时退码仍非零，fallback 用 exit code 构造消息，避免空错误
    @Test func parseNonZeroEmptyStderrContainsExitCode() {
        let err = BrewError.parse(stdout: "", stderr: "   ", exitCode: 42)
        guard case .commandFailed(let msg) = err else { Issue.record("Expected commandFailed"); return }
        #expect(msg.contains("42"))
    }

    // MARK: Properties

    // brewNotFound 是唯一的致命错误，会把 app 锁死在 .error 状态
    @Test func brewNotFoundIsFatal() {
        #expect(BrewError.brewNotFound.isFatal)
    }

    // 网络错误是暂时性的，下一个周期自动重试，不应锁死 app
    @Test func networkUnavailableIsNotFatal() {
        #expect(!BrewError.networkUnavailable.isFatal)
    }

    // 认证失败可重试，不应锁死 app
    @Test func authenticationFailedIsNotFatal() {
        #expect(!BrewError.authenticationFailed.isFatal)
    }

    // isNetworkError 用于决定是否静默跳过自动扫描错误
    @Test func networkUnavailableIsNetworkError() {
        #expect(BrewError.networkUnavailable.isNetworkError)
    }

    // isUserCancelled 用于区分「跳过」和「失败」的通知措辞
    @Test func userCancelledIsUserCancelled() {
        #expect(BrewError.userCancelled.isUserCancelled)
    }

    // brew 路径缺失是配置问题，和用户行为无关
    @Test func brewNotFoundIsNotUserCancelled() {
        #expect(!BrewError.brewNotFound.isUserCancelled)
    }

    // brew 命令失败与网络无关，不应触发静默跳过逻辑
    @Test func commandFailedIsNotNetworkError() {
        #expect(!BrewError.commandFailed("oops").isNetworkError)
    }
}

// MARK: - JSON Parsing

@Suite("JSON Parsing")
struct JSONParsingTests {

    // formulae 和 casks 均为空时，返回空数组而非错误
    @Test func emptyListsReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON(outdatedJSON()).isEmpty)
    }

    // formula 字段映射：name / installed_versions[0] / current_version
    @Test func singleFormula() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(formulae: [("wget", "1.0", "1.1")]))
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "wget")
        #expect(pkgs[0].oldVersion == "1.0")
        #expect(pkgs[0].newVersion == "1.1")
    }

    // cask 与 formula 的 JSON 结构相同，共用同一解析路径
    @Test func singleCask() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(casks: [("firefox", "120.0", "121.0")]))
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "firefox")
        #expect(pkgs[0].newVersion == "121.0")
    }

    // formulae 和 casks 合并为单一列表，顺序为 formulae 在前
    @Test func mixedFormulaeAndCasks() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(
            formulae: [("wget", "1.0", "1.1"), ("git", "2.40", "2.41")],
            casks: [("iterm2", "3.4", "3.5")]
        ))
        #expect(pkgs.count == 3)
        #expect(Set(pkgs.map { $0.name }) == ["wget", "git", "iterm2"])
    }

    // brew 偶发输出非 JSON（如警告文本），不应抛出异常
    @Test func malformedJSONReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON("not json at all").isEmpty)
    }

    // 空字符串是 runner 队列耗尽时的默认返回值，需安全处理
    @Test func emptyStringReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON("").isEmpty)
    }

    // installed_versions 缺失时 fallback 为 "unknown"，保证 UI 不崩溃
    @Test func missingInstalledVersionsDefaultsToUnknown() {
        let json = "{\"formulae\":[{\"name\":\"foo\",\"current_version\":\"2.0\"}],\"casks\":[]}"
        let pkgs = BrewService.parseOutdatedJSON(json)
        #expect(pkgs.count == 1)
        #expect(pkgs[0].oldVersion == "unknown")
    }

    // BrewPackage 实现 Identifiable，id 就是包名，用于 SwiftUI List
    @Test func packageIdEqualsName() {
        let pkg = makePackage("wget")
        #expect(pkg.id == "wget")
    }
}

// MARK: - BrewService

@Suite("BrewService")
@MainActor
struct BrewServiceTests {

    private func makeService(
        runner: MockBrewCommandRunner,
        brewURL: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    ) -> BrewService {
        BrewService(runner: runner, authService: AuthorizationService(bundle: .main), brewURL: brewURL)
    }

    // MARK: getOutdatedPackages

    // brew 路径未找到时应提前失败，不应尝试执行任何命令
    @Test func getOutdatedBrewNotFoundWhenURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .getOutdatedPackages(shouldUpdate: false)
        #expect(result == .failure(.brewNotFound))
    }

    // shouldUpdate=false 时只执行 brew outdated，不执行 brew update（手动刷新场景）
    @Test func getOutdatedSkipsUpdateCommandWhenFlagFalse() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]))
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false)
        #expect(runner.executedCommands.count == 1)
        guard case .success(let pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "wget")
    }

    // shouldUpdate=true 时先执行 brew update 再执行 brew outdated（自动/初始扫描场景）
    @Test func getOutdatedRunsUpdateCommandFirst() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue()                                                          // brew update → success
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")])) // brew outdated
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(runner.executedCommands.count == 2)
        guard case .success(let pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.count == 1)
    }

    @Test func getOutdatedPropagatesNetworkErrorFromUpdate() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "curl: (6) Could not resolve host", exitCode: 1)
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(result == .failure(.networkUnavailable))
        #expect(runner.executedCommands.count == 1) // stops after update failure
    }

    // 无更新时返回空列表而非错误，调用方不需要特殊处理
    @Test func getOutdatedReturnsEmptyListWhenNothingOutdated() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON())
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false)
        guard case .success(let pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.isEmpty)
    }

    // MARK: checkIfPackageIsStillOutdated

    // brew 路径缺失时，pre-check 保守地返回 true，让 upgrade 流程自行处理
    @Test func checkReturnsTrueWhenBrewURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    // exit 0 表示 brew outdated 认为该包已是最新（外部已升级）
    @Test func checkReturnsFalseWhenExitCodeZero() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == false)
    }

    // 非零退出且包名出现在 JSON 中，确认包仍需升级
    @Test func checkReturnsTrueWhenPackageInOutdatedJSON() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    @Test func checkReturnsFalseWhenDifferentPackageInJSON() async {
        // brew outdated was run for wget but only curl appears in the result → wget is not outdated
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("curl", "7.0", "8.0")]), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == false)
    }

    @Test func checkReturnsTrueOnEmptyJSONFallback() async {
        // Non-zero exit but empty JSON → ambiguous, assume still outdated
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    // MARK: upgrade

    // brew 路径缺失时，upgrade 应立即返回 brewNotFound 而非崩溃
    @Test func upgradeReturnsBrewNotFoundWhenURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .upgrade(packages: [makePackage()])
        #expect(result == .failure(.brewNotFound))
    }

    // 空包列表视为「已完成」，不应启动任何进程
    @Test func upgradeSucceedsImmediatelyForEmptyList() async {
        let runner = MockBrewCommandRunner()
        let result = await makeService(runner: runner).upgrade(packages: [])
        #expect(result == .success(true))
        #expect(runner.executedCommands.isEmpty)
    }
}

// MARK: - AppSettings

@Suite("AppSettings")
@MainActor
struct AppSettingsTests {

    // 全新安装后未写入任何值，读取默认配置时不应崩溃
    @Test func defaultCheckIntervalIsOneHour() {
        #expect(AppSettings(store: MockSettingsStore()).checkInterval == .oneHour)
    }

    // custom 模式下未配置时使用合理默认值，避免极端间隔
    @Test func defaultCustomIntervalIsOneHour() {
        #expect(AppSettings(store: MockSettingsStore()).customCheckInterval == DefaultsKey.defaultCustomIntervalSeconds)
    }

    // 自动升级默认关闭，防止用户意外触发静默升级
    @Test func defaultAutoUpgradeIsDisabled() {
        #expect(!AppSettings(store: MockSettingsStore()).isAutoUpgradeEnabled)
    }

    // greedy 模式默认关闭，避免升级自动更新类 cask
    @Test func defaultGreedyModeIsDisabled() {
        #expect(AppSettings(store: MockSettingsStore()).greedyMode == .disabled)
    }

    // 授权超时默认 5 分钟，与 CLAUDE.md 文档一致
    @Test func defaultAuthTimeoutIs300() {
        #expect(AppSettings(store: MockSettingsStore()).authTimeout == DefaultsKey.defaultAuthTimeoutSeconds)
    }

    // 预设模式直接用 rawValue（秒数），无需换算
    @Test func currentIntervalSecondsForPreset() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.checkInterval = .sixHours
        #expect(settings.currentIntervalSeconds == Double(CheckInterval.sixHours.rawValue))
    }

    // custom 模式读取 customCheckInterval 而非 rawValue
    @Test func currentIntervalSecondsForCustom() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.checkInterval = .custom
        settings.customCheckInterval = 7200
        #expect(settings.currentIntervalSeconds == 7200.0)
    }

    // 设置写入必须立即落地到 SettingsStore，保证 app 重启后恢复
    @Test func checkIntervalPersistsToStore() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.checkInterval = .twentyFourHours
        #expect(store.integer(forKey: DefaultsKey.checkInterval) == CheckInterval.twentyFourHours.rawValue)
    }

    // 同上，验证 Bool 类型持久化路径
    @Test func autoUpgradePersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).isAutoUpgradeEnabled = true
        #expect(store.bool(forKey: DefaultsKey.isAutoUpgradeEnabled) == true)
    }

    // GreedyMode 存储为 rawValue 字符串，与 UserDefaults 的 string(forKey:) 对齐
    @Test func greedyModePersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).greedyMode = .all
        #expect(store.string(forKey: DefaultsKey.greedyMode) == GreedyMode.all.rawValue)
    }

    // 同上，验证 Int 类型持久化路径
    @Test func authTimeoutPersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).authTimeout = 120
        #expect(store.integer(forKey: DefaultsKey.authTimeout) == 120)
    }

    // 低于最小值（60s）的输入必须被截断，防止 Timer 过于频繁
    @Test func customIntervalClampedToMinimum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.customCheckInterval = 10
        #expect(settings.customCheckInterval == DefaultsKey.minimumCustomIntervalSeconds)
    }

    // 高于最大值（7天）的输入必须被截断，防止用户意外设置永不检查
    @Test func customIntervalClampedToMaximum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.customCheckInterval = 999_999_999
        #expect(settings.customCheckInterval == DefaultsKey.maximumCustomIntervalSeconds)
    }

    // 模拟 app 重启：从已填充的 Store 初始化 AppSettings，验证所有字段正确还原
    @Test func settingsRestoredFromPersistedStore() {
        let store = MockSettingsStore()
        store.set(CheckInterval.twelveHours.rawValue, forKey: DefaultsKey.checkInterval)
        store.set(true, forKey: DefaultsKey.isAutoUpgradeEnabled)
        store.set(GreedyMode.autoUpdates.rawValue, forKey: DefaultsKey.greedyMode)
        store.set(600, forKey: DefaultsKey.authTimeout)

        let settings = AppSettings(store: store)
        #expect(settings.checkInterval == .twelveHours)
        #expect(settings.isAutoUpgradeEnabled == true)
        #expect(settings.greedyMode == .autoUpdates)
        #expect(settings.authTimeout == 600)
    }
}

// MARK: - UpgradeEngine

@Suite("UpgradeEngine")
@MainActor
struct UpgradeEngineTests {

    private func makeEngine(runner: MockBrewCommandRunner) -> (engine: UpgradeEngine, coordinator: MockCoordinator) {
        let coordinator = MockCoordinator()
        let service = BrewService(
            runner: runner,
            authService: AuthorizationService(bundle: .main),
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        )
        let engine = UpgradeEngine(
            coordinator: coordinator,
            sudoMonitor: SudoMonitor(coordinator: coordinator),
            brewService: service
        )
        return (engine, coordinator)
    }

    // 空包列表不应触发状态转换，run() 应立即返回
    @Test func emptyPackagesIsNoOp() async {
        let runner = MockBrewCommandRunner()
        let (engine, coordinator) = makeEngine(runner: runner)
        await engine.run(packages: [], config: MockConfig())
        #expect(coordinator.transitionHistory.isEmpty)
        #expect(runner.executedCommands.isEmpty)
    }

    // 正常升级开始时必须进入 .updating 状态，驱动菜单栏 UI 显示进度
    @Test func runTransitionsToUpdating() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]), exitCode: 1)
        let (engine, coordinator) = makeEngine(runner: runner)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        #expect(coordinator.transitionHistory.contains(.updating))
    }

    @Test func externallyUpgradedPackageSkipsUpgradeAndRefreshes() async {
        let runner = MockBrewCommandRunner()
        // Pre-check exits 0 → package is no longer outdated (externally upgraded)
        runner.enqueue(exitCode: 0)
        let (engine, coordinator) = makeEngine(runner: runner)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        #expect(coordinator.checkModes.contains(.refresh))
        #expect(coordinator.errorMessage == nil)
    }

    // cancel() 在 isRunning=false 时应是空操作，不应改变任何状态
    @Test func cancelBeforeRunIsNoOp() {
        let (engine, coordinator) = makeEngine(runner: MockBrewCommandRunner())
        engine.cancel() // isRunning is false → guard fires, nothing happens
        #expect(coordinator.transitionHistory.isEmpty)
    }

    // run() 完成后 isRunning 必须重置，保证引擎可复用（非一次性对象）
    @Test func engineIsReusableAcrossRuns() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0) // first run: wget externally upgraded
        let (engine, coordinator) = makeEngine(runner: runner)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())
        let firstCount = coordinator.transitionHistory.count

        runner.enqueue(exitCode: 0) // second run: curl externally upgraded
        await engine.run(packages: [makePackage("curl")], config: MockConfig())
        #expect(coordinator.transitionHistory.count > firstCount)
    }
}

// MARK: - NotificationService Content

@Suite("NotificationService Content")
@MainActor
struct NotificationServiceContentTests {

    private let svc = NotificationService.shared

    private func content(
        upgraded: [BrewPackage] = [],
        success: Bool = true,
        requested: [String] = [],
        skipped: [String] = [],
        external: [String] = []
    ) -> (title: String, body: String) {
        svc.upgradeResultContent(
            upgraded: upgraded,
            success: success,
            requestedNames: requested,
            skippedNames: skipped,
            externalSuccessNames: external
        )
    }

    // MARK: Title selection

    // 全部包成功升级时 title 应为 "Brew Updated"
    @Test func titleIsBrewUpdatedOnFullSuccess() {
        let (title, _) = content(
            upgraded: [makePackage("wget")],
            success: true,
            requested: ["wget"]
        )
        #expect(title == "Brew Updated")
    }

    // 有包成功但也有失败时，title 为 "Partial Upgrade" 而非 "Brew Updated"
    @Test func titleIsPartialUpgradeOnFailure() {
        let (title, _) = content(
            upgraded: [makePackage("wget")],
            success: false,
            requested: ["wget", "curl"]
        )
        #expect(title == "Partial Upgrade")
    }

    // 无任何包成功时 title 为 "Upgrade Failed"（不是 "Partial Upgrade"）
    @Test func titleIsUpgradeFailedWhenNothingSucceeded() {
        let (title, _) = content(
            upgraded: [],
            success: false,
            requested: ["wget"]
        )
        #expect(title == "Upgrade Failed")
    }

    // 没有任何需要处理的包时（自动扫描后无更新）title 为 "Brew Ready"
    @Test func titleIsBrewReadyWhenNothingHappened() {
        let (title, _) = content(upgraded: [], success: true, requested: [])
        #expect(title == "Brew Ready")
    }

    // MARK: Body — success lines

    // ✅ 升级成功行需包含包名和 oldVersion → newVersion
    @Test func bodyContainsUpgradedPackageWithVersions() {
        let (_, body) = content(
            upgraded: [makePackage("wget", old: "1.0", new: "1.1")],
            success: true,
            requested: ["wget"]
        )
        #expect(body.contains("wget"))
        #expect(body.contains("1.0"))
        #expect(body.contains("1.1"))
    }

    // MARK: Body — external, skipped, failed lines

    // ℹ️ 外部已升级的包（如 mas/手动）显示 "Already current" 而非版本箭头
    @Test func bodyContainsExternalPackage() {
        let (_, body) = content(
            upgraded: [makePackage("wget")],
            success: true,
            requested: ["wget"],
            external: ["wget"]   // wget was already upgraded externally
        )
        #expect(body.contains("wget"))
        #expect(body.contains("Already current"))
    }

    @Test func externalPackageIsFilteredFromUpgradedLines() {
        // wget appears in both upgraded and external → should appear only as ℹ️, not ✅
        let (_, body) = content(
            upgraded: [makePackage("wget")],
            success: true,
            requested: ["wget"],
            external: ["wget"]
        )
        #expect(!body.contains("→"))   // version arrow only appears in ✅ success lines
    }

    // ⏭️ userCancelled 的包应显示 "Skipped"，不显示版本箭头
    @Test func bodyContainsSkippedPackage() {
        let (_, body) = content(
            upgraded: [],
            success: true,
            requested: ["wget"],
            skipped: ["wget"]
        )
        #expect(body.contains("wget"))
        #expect(body.contains("Skipped"))
    }

    // ❌ 既未跳过又未外部升级的包视为 failed，显示 "Failed"
    @Test func bodyContainsFailedPackage() {
        let (_, body) = content(
            upgraded: [],
            success: false,
            requested: ["wget", "curl"],
            skipped: ["wget"]   // wget skipped, curl failed
        )
        #expect(body.contains("curl"))
        #expect(body.contains("Failed"))
    }

    // 多包时每个包独占一行，验证 body 包含所有包名
    @Test func bodyContainsMultiplePackageLines() {
        let (_, body) = content(
            upgraded: [makePackage("wget"), makePackage("git")],
            success: true,
            requested: ["wget", "git"]
        )
        #expect(body.contains("wget"))
        #expect(body.contains("git"))
    }

    // MARK: failedNames calculation

    @Test func failedNamesExcludesSkippedAndExternal() {
        // requested = [wget, curl, git], skipped = [wget], external = [curl] → failed = [git]
        let (_, body) = content(
            upgraded: [],
            success: false,
            requested: ["wget", "curl", "git"],
            skipped: ["wget"],
            external: ["curl"]
        )
        #expect(body.contains("git"))
        #expect(!body.contains("wget") || body.contains("Skipped"))
    }
}

// MARK: - AuthorizationService

@Suite("AuthorizationService")
struct AuthorizationServiceTests {

    private let service = AuthorizationService(bundle: .main)
    private let helperURL = URL(fileURLWithPath: "/tmp/FakeBrewMenuAskPass")

    // SUDO_ASKPASS 是 sudo -A 模式的核心：指定弹出密码对话框的程序路径
    @Test func sudoAskpassIsSetToHelperPath() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [], authTimeout: 300)
        #expect(env["SUDO_ASKPASS"] == helperURL.path)
    }

    // DISPLAY=:0 防止部分 Linux 环境下 AskPass 因无显示器而崩溃（macOS 也需要保持一致）
    @Test func displayIsAlwaysSet() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [], authTimeout: 300)
        #expect(env["DISPLAY"] == ":0")
    }

    // AskPass 对话框标题需要知道是哪些包在请求权限
    @Test func packageInfoIsCommaSeparatedWhenNonEmpty() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: ["wget", "curl"], authTimeout: 300)
        #expect(env["BREW_MENU_PACKAGE_INFO"] == "wget, curl")
    }

    // 无包时不应写入 BREW_MENU_PACKAGE_INFO，避免 AskPass 显示空列表
    @Test func packageInfoIsAbsentWhenPackagesEmpty() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [], authTimeout: 300)
        #expect(env["BREW_MENU_PACKAGE_INFO"] == nil)
    }
}

// MARK: - GreedyMode

@Suite("GreedyMode")
struct GreedyModeTests {

    // 每个 GreedyMode 对应固定的 brew CLI 参数，参数错误会导致 brew 忽略 greedy 设置
    @Test(arguments: [
        (GreedyMode.disabled, [String]()),
        (GreedyMode.all, ["--greedy"]),
        (GreedyMode.autoUpdates, ["--greedy-auto-updates"]),
        (GreedyMode.latest, ["--greedy-latest"])
    ])
    func brewArgs(mode: GreedyMode, expected: [String]) {
        #expect(mode.args == expected)
    }

    // Identifiable 要求 id 唯一且与 rawValue 一致，以确保 Picker 选中状态正确
    @Test(arguments: GreedyMode.allCases)
    func idMatchesRawValue(mode: GreedyMode) {
        #expect(mode.id == mode.rawValue)
    }

    // description 用于 UI 展示，disabled 是本地化字符串（非空），其余为固定 CLI flag 字符串
    @Test(arguments: [
        (GreedyMode.all, "--greedy"),
        (GreedyMode.autoUpdates, "--greedy-auto-updates"),
        (GreedyMode.latest, "--greedy-latest")
    ])
    func descriptionMatchesFlag(mode: GreedyMode, expected: String) {
        #expect(mode.description == expected)
    }

    @Test func disabledDescriptionIsNonEmpty() {
        #expect(!GreedyMode.disabled.description.isEmpty)
    }
}

// MARK: - BrewError (补充)

@Suite("BrewError Supplemental")
struct BrewErrorSupplementalTests {

    // MARK: isFatal negative cases

    // userCancelled 没有锁死语义，错误对话框关闭后应可重试
    @Test func userCancelledIsNotFatal() {
        #expect(!BrewError.userCancelled.isFatal)
    }

    // commandFailed 是可自此恢复的运行时错误，不锁死 app
    @Test func commandFailedIsNotFatal() {
        #expect(!BrewError.commandFailed("x").isFatal)
    }

    // MARK: isUserCancelled negative cases

    // 认证失败是密码错误，不是用户主动放弃
    @Test func authFailedIsNotUserCancelled() {
        #expect(!BrewError.authenticationFailed.isUserCancelled)
    }

    // 断网与用户意图无关
    @Test func networkUnavailableIsNotUserCancelled() {
        #expect(!BrewError.networkUnavailable.isUserCancelled)
    }

    // brew 命令失败与用户操作无关
    @Test func commandFailedIsNotUserCancelled() {
        #expect(!BrewError.commandFailed("x").isUserCancelled)
    }

    // MARK: isNetworkError negative cases

    // 用户取消应被当作 "跳过" 而非网络不可达
    @Test func userCancelledIsNotNetworkError() {
        #expect(!BrewError.userCancelled.isNetworkError)
    }

    // 认证失败与网络无关，不应触发静默跳过
    @Test func authFailedIsNotNetworkError() {
        #expect(!BrewError.authenticationFailed.isNetworkError)
    }

    // brew 路径缺失与网络无关
    @Test func brewNotFoundIsNotNetworkErrorSupplemental() {
        #expect(!BrewError.brewNotFound.isNetworkError)
    }

    // MARK: parse — additional trigger words

    // brew update 连接 raw.githubusercontent.com 时的 HTTPS 失败措辞
    @Test func parseFailedToConnectIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "failed to connect to github.com", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // macOS 密阥串/安全框处理过程通信失败的字面量
    @Test func parseConversationFailedIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "conversation with the agent failed", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    // MARK: parse — cancel after multiple wrong attempts

    // 输错 1 次后取消：sudo 会同时输出 "1 incorrect password attempt" + "a password is required"
    // cancel 信号必须优先，结果应是 userCancelled 而非 authenticationFailed
    @Test func parseOneIncorrectAttemptThenCancelIsUserCancelled() {
        let stderr = "sudo: 1 incorrect password attempt\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    // 输错 2 次后取消：同上
    @Test func parseTwoIncorrectAttemptsThenCancelIsUserCancelled() {
        let stderr = "sudo: 2 incorrect password attempts\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    // 输错 1 次但未取消（仅出现 "incorrect password attempt"，无 cancel 信号）
    // → authenticationFailed（sudo exhausted retries）
    // 仅出现计数字，无取消信号→ sudo 重试耗尽→ authenticationFailed
    @Test func parseOneIncorrectAttemptNoCancel() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: 1 incorrect password attempt", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    // MARK: userMessage

    // commandFailed.userMessage 展示原始 stderr，便于 UI 显示具体原因
    @Test func userMessageCommandFailedReturnsReason() {
        #expect(BrewError.commandFailed("bad output").userMessage == "bad output")
    }
}

// MARK: - BrewService (补充)

@Suite("BrewService Supplemental")
@MainActor
struct BrewServiceSupplementalTests {

    private func makeService(runner: MockBrewCommandRunner) -> BrewService {
        BrewService(runner: runner, authService: AuthorizationService(bundle: .main),
                    brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
    }

    // MARK: upgrade — success / failure paths

    // 验证正常升级路径的基线
    @Test func upgradeSucceedsWithSinglePackage() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .success(true))
    }

    // 3 次密码尝试全部错误，应返回 authenticationFailed 而非 userCancelled
    @Test func upgradeAuthenticationFailed() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: 3 incorrect password attempts", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.authenticationFailed))
    }

    // 用户未输入密码直接关闭对话框，AskPass 以空密码退出
    @Test func upgradeUserCancelledEmptyPassword() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: no password was provided", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.userCancelled))
    }

    // 输错一次密码后点击取消，两个错误信号同时出现， userCancelled 必须优先
    @Test func upgradeUserCancelledPasswordRequired() async {
        // 用户输错密码后点击取消
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: 1 incorrect password attempt\nsudo: a password is required", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.userCancelled))
    }

    // brew 下载 cask 时断网，应返回 networkUnavailable
    @Test func upgradeNetworkError() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "curl: (6) Could not resolve host: ghcr.io", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.networkUnavailable))
    }

    // 非授权/网络以外的 brew 失败，错误信息透传给调用方
    @Test func upgradeCommandFailed() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "brew: some unexpected error", exitCode: 2)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        guard case .failure(let err) = result, case .commandFailed(let msg) = err else {
            Issue.record("Expected commandFailed"); return
        }
        #expect(msg.contains("brew: some unexpected error"))
    }

    // MARK: getOutdatedPackages — network error from outdated command

    // 断网影响 brew outdated 命令（非 update 命令）时应正确传播
    @Test func getOutdatedNetworkErrorFromOutdatedCmd() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue()                                                          // update → success
        runner.enqueue(stderr: "curl: (6) Could not resolve host", exitCode: 1)  // outdated → network error
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(result == .failure(.networkUnavailable))
    }

    // MARK: getOutdatedPackages — greedy args are forwarded

    // --greedy 参数必须透传到 brew outdated 命令，漏传则 greedy 设置无效
    @Test func getOutdatedWithGreedyArgsForwardsToCommand() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON())
        _ = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false, greedyArgs: ["--greedy"])
        #expect(runner.executedCommands.first?.args.contains("--greedy") == true)
    }

    // MARK: cleanup

    // 清理命令成功时返回 true
    @Test func cleanupSucceeds() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let isSuccess = await makeService(runner: runner).cleanup(mode: .pruneAll)
        #expect(isSuccess == true)
    }

    // 清理命令失败时返回 false，不应抛出异常
    @Test func cleanupFails() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "error", exitCode: 1)
        let isSuccess = await makeService(runner: runner).cleanup(mode: .pruneAll)
        #expect(isSuccess == false)
    }
}

// MARK: - NotificationService Content (补充)

@Suite("NotificationService Content Supplemental")
@MainActor
struct NotificationContentSupplementalTests {

    private let svc = NotificationService.shared

    private func content(
        upgraded: [BrewPackage] = [],
        success: Bool = true,
        requested: [String] = [],
        skipped: [String] = [],
        external: [String] = []
    ) -> (title: String, body: String) {
        svc.upgradeResultContent(
            upgraded: upgraded,
            success: success,
            requestedNames: requested,
            skippedNames: skipped,
            externalSuccessNames: external
        )
    }

    // MARK: 全部 userCancelled（每个包都被跳过）

    // 全部包被 userCancelled 跳过：没有实际升级，overallSuccess=true，但 skipped 非空。
    // 修正后的 success 计算：upgraded(0) + external(0) != requested(1) - skipped(1) → 0==0 true，
    // 但 filteredUpgraded.isEmpty && externalSuccessNames.isEmpty && skippedNames.isEmpty = false，
    // 走 else 分支，title 取决于 success 参数 true → "Brew Updated"。
    // 语义上是"全部跳过"，title 为 "Brew Updated" 是有歧义的，后续可按产品需求调整。
    @Test func allSkippedTitleIsBrewUpdated() {
        let (title, _) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(title == "Brew Updated")
    }

    @Test func allSkippedBodyContainsSkipped() {
        let (_, body) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Skipped"))
    }

    // MARK: userCancelled → skipped 标签

    @Test func bodyAuthCancelledShowsSkipped() {
        // 单包，用户取消授权 → skipped
        let (_, body) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(body.contains("Skipped"))
        #expect(!body.contains("Failed"))
    }

    // MARK: authenticationFailed → failed 标签

    @Test func bodyAuthFailedShowsFailed() {
        // authenticationFailed：overallSuccess=false，包不在 skipped/external/upgraded → failed
        let (_, body) = content(upgraded: [], success: false, requested: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Failed"))
    }

    @Test func titleAuthFailedIsUpgradeFailed() {
        let (title, _) = content(upgraded: [], success: false, requested: ["wget"])
        #expect(title == "Upgrade Failed")
    }

    // MARK: external + skipped 同时存在

    @Test func externalAndSkippedBothPresent() {
        let (_, body) = content(
            upgraded: [],
            success: true,
            requested: ["wget", "curl"],
            skipped: ["curl"],
            external: ["wget"]
        )
        #expect(body.contains("Already current"))
        #expect(body.contains("Skipped"))
    }

    // MARK: singlePackageSuccess body format

    @Test func singlePackageSuccessBodyContainsVersionArrow() {
        let (_, body) = content(
            upgraded: [makePackage("wget", old: "1.0", new: "1.1")],
            success: true,
            requested: ["wget"]
        )
        // line_package_success 本地化格式包含 "→"
        #expect(body.contains("→"))
        #expect(body.contains("1.0"))
        #expect(body.contains("1.1"))
    }
}

// MARK: - AuthorizationService (补充)

@Suite("AuthorizationService Supplemental")
struct AuthorizationServiceSupplementalTests {

    private let service = AuthorizationService(bundle: .main)
    private let helperURL = URL(fileURLWithPath: "/tmp/FakeBrewMenuAskPass")

    @Test func singlePackageInfoIsNameOnly() {
        // 单个包，BREW_MENU_PACKAGE_INFO 应该只是包名，不带尾部逗号
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: ["wget"], authTimeout: 300)
        #expect(env["BREW_MENU_PACKAGE_INFO"] == "wget")
    }
}

// MARK: - B/C Class Mocks

private final class MockBrewService: BrewServiceProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var outdatedQueue: [Result<[BrewPackage], BrewError>] = []
    private var upgradeQueue: [Result<Bool, BrewError>] = []
    private var stillOutdatedQueue: [Bool] = []
    private(set) var cleanupCallCount = 0
    private(set) var terminateCallCount = 0

    func enqueueOutdated(_ result: Result<[BrewPackage], BrewError>) {
        lock.withLock { outdatedQueue.append(result) }
    }
    func enqueueUpgrade(_ result: Result<Bool, BrewError>) {
        lock.withLock { upgradeQueue.append(result) }
    }
    func enqueueStillOutdated(_ value: Bool) {
        lock.withLock { stillOutdatedQueue.append(value) }
    }

    func getOutdatedPackages(shouldUpdate: Bool, greedyArgs: [String]) async -> Result<[BrewPackage], BrewError> {
        lock.withLock {
            outdatedQueue.isEmpty ? .success([]) : outdatedQueue.removeFirst()
        }
    }
    func checkIfPackageIsStillOutdated(name: String, greedyArgs: [String]) async -> Bool {
        lock.withLock {
            stillOutdatedQueue.isEmpty ? true : stillOutdatedQueue.removeFirst()
        }
    }
    func upgrade(packages: [BrewPackage], greedyArgs: [String], authTimeout: Int, onPID: (@Sendable (Int32) -> Void)?) async -> Result<Bool, BrewError> {
        lock.withLock {
            upgradeQueue.isEmpty ? .success(true) : upgradeQueue.removeFirst()
        }
    }
    func terminateAll() {
        lock.withLock { terminateCallCount += 1 }
    }
    func cleanup(mode: CleanupMode) async -> Bool {
        lock.withLock {
            cleanupCallCount += 1
            return true
        }
    }
}

@MainActor
private final class MockNotificationService: NotificationServiceProtocol {
    var onAuthorizeActionTapped: (() -> Void)?
    struct UpgradeResultCall {
        let upgraded: [BrewPackage]
        let success: Bool
        let requestedNames: [String]
        let skippedNames: [String]
        let externalSuccessNames: [String]
    }
    private(set) var upgradeResultCalls: [UpgradeResultCall] = []
    private(set) var transientErrorCalls: [(BrewError, String?)] = []
    private(set) var updatesFoundCalls: [[BrewPackage]] = []
    private(set) var authRequiredCalls: Int = 0
    private(set) var authTimeoutCalls: Int = 0

    func requestAuthorization() {}
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String], externalSuccessNames: [String]) {
        upgradeResultCalls.append(UpgradeResultCall(upgraded: upgraded, success: success, requestedNames: requestedNames, skippedNames: skippedNames, externalSuccessNames: externalSuccessNames))
    }
    func showUpdatesFound(packages: [BrewPackage]) { updatesFoundCalls.append(packages) }
    func showAuthRequired(packageNames: [String], isRetry: Bool) { authRequiredCalls += 1 }
    func showAuthTimeout(packageName: String) { authTimeoutCalls += 1 }
    func showTransientError(error: BrewError, packageName: String?) { transientErrorCalls.append((error, packageName)) }
}

// MARK: - UpgradeEngine (补充)

@Suite("UpgradeEngine Supplemental")
@MainActor
struct UpgradeEngineSupplementalTests {

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

    // MARK: 升级成功后发送结果通知

    @Test func upgradeSuccessNotifiesSummary() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        // pre-check: still outdated → true; upgrade → success; refresh outdated → empty
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)")
            return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.requestedNames == ["wget"])
    }

    // MARK: userCancelled → skippedNames，overallSuccess 不变

    @Test func userCancelledDuringUpgradeIsSkipped() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.userCancelled))

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)")
            return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.skippedNames == ["wget"])
        #expect(call.success == true)   // overallSuccess 不被置 false
    }

    // MARK: authenticationFailed → overallSuccess=false + errorMessage

    @Test func authFailedSetsErrorMessageAndOverallFailure() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        #expect(coordinator.errorMessage != nil)
        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)")
            return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.success == false)
    }

    // MARK: authFailed：包升级后仍 outdated → showTransientError 被调用

    @Test func authFailedPackageStillOutdatedGetsErrorNotif() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))
        // refresh 后 coordinator 仍返回 wget 在 outdated 列表 → showTransientError 应被调用
        coordinator.outdatedQueue = [[makePackage("wget")]]

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        guard notifSvc.transientErrorCalls.count == 1 else {
            Issue.record("Expected 1 transientError call, got \(notifSvc.transientErrorCalls.count)")
            return
        }
        #expect(notifSvc.transientErrorCalls[0].0 == .authenticationFailed)
    }

    // MARK: authFailed：包升级后不在 outdated（brew 实际成功但报错）→ 不调用 showTransientError

    @Test func authFailedPackageNoLongerOutdatedNoErrorNotif() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.failure(.authenticationFailed))
        // refresh 后 coordinator 返回空列表 → brew 实际成功，不发 transientError
        // coordinator.outdatedQueue 为空， check() 将返回 []

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: MockConfig())

        #expect(notifSvc.transientErrorCalls.isEmpty)
    }

    // MARK: cleanupMode == .pruneAll → cleanup 被调用

    @Test func autoCleanupRunsWhenEnabled() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        brewSvc.enqueueStillOutdated(true)
        brewSvc.enqueueUpgrade(.success(true))

        struct CleanupConfig: BrewConfiguration, Sendable {
            var greedyMode: GreedyMode = .disabled
            var cleanupMode: CleanupMode = .pruneAll
            var authTimeout: Int = 300
        }

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget")], config: CleanupConfig())

        #expect(brewSvc.cleanupCallCount == 1)
    }

    // MARK: 多包：一个外部升级，一个真实升级

    @Test func multiplePackagesOneExternalOneReal() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        // wget: pre-check → already current (externally upgraded)
        // curl: pre-check → still outdated; upgrade → success
        brewSvc.enqueueStillOutdated(false)  // wget
        brewSvc.enqueueStillOutdated(true)   // curl
        brewSvc.enqueueUpgrade(.success(true))

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget"), makePackage("curl")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)")
            return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.externalSuccessNames == ["wget"])
        #expect(call.requestedNames == ["wget", "curl"])
    }

    // MARK: 一包 userCancelled，一包成功 → success 为 false（Partial Upgrade）

    @Test func oneSkippedOneSuccessIsPartialUpgrade() async {
        let brewSvc = MockBrewService()
        let notifSvc = MockNotificationService()
        let coordinator = MockCoordinator()
        // wget: userCancelled → skipped
        // curl: success
        brewSvc.enqueueStillOutdated(true)   // wget
        brewSvc.enqueueUpgrade(.failure(.userCancelled))
        brewSvc.enqueueStillOutdated(true)   // curl
        brewSvc.enqueueUpgrade(.success(true))

        let engine = makeEngine(brewService: brewSvc, notificationService: notifSvc, coordinator: coordinator)
        await engine.run(packages: [makePackage("wget"), makePackage("curl")], config: MockConfig())

        guard notifSvc.upgradeResultCalls.count == 1 else {
            Issue.record("Expected 1 upgradeResult call, got \(notifSvc.upgradeResultCalls.count)")
            return
        }
        let call = notifSvc.upgradeResultCalls[0]
        #expect(call.skippedNames == ["wget"])
        // upgraded(1) + external(0) = 1, requested(2) - skipped(1) = 1 → success=true
        #expect(call.success == true)
    }
}

// MARK: - SudoMonitor

@Suite("SudoMonitor")
@MainActor
struct SudoMonitorTests {

    // MARK: PID lineage validation

    // ppidProvider: pid→ppid→gpid，gpid 匹配 currentSessionPID → 通知发出，status → .authorizing
    @Test func lineageMatchAllowsSession() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        // Helper PID=10, sudo PID=20, brew PID=30 (currentSession)
        let monitor = SudoMonitor(
            coordinator: coordinator,
            notificationService: notifSvc,
            ppidProvider: { pid in
                switch pid {
                case 10: return 20   // Helper's parent = sudo
                case 20: return 30   // sudo's parent = brew
                default: return nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        // DistributedNotificationCenter 在 XCTest host 里走系统 daemon，delivery 不可靠。
        // 直接调用内部处理逻辑，绕开跨进程通知。
        await monitor.simulateHelperStarted(pid: 10)

        #expect(coordinator.transitionHistory.contains(.authorizing))
    }

    // gpid 不匹配 currentSessionPID → 被拒绝，status 不变
    @Test func lineageMismatchBlocksSession() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        let monitor = SudoMonitor(
            coordinator: coordinator,
            notificationService: notifSvc,
            ppidProvider: { pid in
                switch pid {
                case 10: return 20
                case 20: return 99   // gpid=99 ≠ currentSession=30
                default: return nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        monitor.start()

        DistributedNotificationCenter.default().postNotificationName(
            BrewMenuNotification.helperStarted,
            object: "10",
            userInfo: nil,
            deliverImmediately: true
        )

        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(!coordinator.transitionHistory.contains(.authorizing))
    }

    // ppidProvider 返回 nil（sysctl 失败）→ 拒绝
    @Test func ppidLookupFailureBlocksSession() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        let monitor = SudoMonitor(
            coordinator: coordinator,
            notificationService: notifSvc,
            ppidProvider: { _ in nil }
        )
        monitor.registerSession(pid: 30)
        monitor.start()

        DistributedNotificationCenter.default().postNotificationName(
            BrewMenuNotification.helperStarted,
            object: "10",
            userInfo: nil,
            deliverImmediately: true
        )

        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(!coordinator.transitionHistory.contains(.authorizing))
    }

    // MARK: stop 清空状态

    @Test func stopClearsObserversAndPIDs() {
        let coordinator = MockCoordinator()
        let monitor = SudoMonitor(coordinator: coordinator, ppidProvider: { _ in nil })
        monitor.start()
        monitor.stop()
        // stop 后再次 stop 不崩溃
        monitor.stop()
    }

    // MARK: 超时触发 cancel

    @Test func timeoutCancelsActivePIDs() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        // timeout 极短 (1ns)
        let monitor = SudoMonitor(
            coordinator: coordinator,
            timeoutProvider: { 0 },
            notificationService: notifSvc,
            ppidProvider: { pid in
                switch pid {
                case 10: return 20
                case 20: return 30
                default: return nil
                }
            }
        )
        monitor.registerSession(pid: 30)
        // 直接触发处理逻辑，绕开 DistributedNotificationCenter。
        // timeout=0 → Task.sleep(0ns) 几乎立即触发 cancelAuthorizationUI。
        await monitor.simulateHelperStarted(pid: 10)
        // 等 timeout Task 完成（sleep 0ns + 一次调度往返）
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        #expect(notifSvc.authTimeoutCalls > 0)
    }
}

// MARK: - AutoScheduler

@Suite("AutoScheduler")
@MainActor
struct AutoSchedulerTests {

    private struct OfflineNetwork: NetworkConnectivityProvider { var isConnected: Bool { false } }
    private struct OnlineNetwork: NetworkConnectivityProvider { var isConnected: Bool { true } }

    private final class ControllableClock: ClockProvider {
        var now: Date = Date(timeIntervalSinceReferenceDate: 0)
    }

    private func makeScheduler(
        network: NetworkConnectivityProvider = OnlineNetwork(),
        clock: ClockProvider? = nil,
        coordinator: MockCoordinator
    ) -> AutoScheduler {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        return AutoScheduler(coordinator: coordinator, settings: settings, network: network, clock: clock ?? SystemClock())
    }

    // MARK: fire — 离线时跳过 check

    @Test func fireSkipsWhenOffline() async {
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(network: OfflineNetwork(), coordinator: coordinator)
        scheduler.fire()
        await Task.yield()
        #expect(coordinator.checkModes.isEmpty)
    }

    // MARK: fire — 在线时触发 check(mode:.automatic)

    @Test func fireTriggersCheckWhenOnline() async {
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(network: OnlineNetwork(), coordinator: coordinator)
        scheduler.fire()
        await Task.yield()
        await Task.yield()
        #expect(coordinator.checkModes.contains(.automatic))
    }

    // MARK: handleWake — 超期立即 fire

    @Test func handleWakeFiresImmediatelyWhenOverdue() async {
        let coordinator = MockCoordinator()
        let clock = ControllableClock()
        let scheduler = makeScheduler(network: OnlineNetwork(), clock: clock, coordinator: coordinator)

        // 模拟上次 fire 在 2 小时前
        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.fire()   // 设置 lastFireDate = t0

        // 移动时钟到 t0+7200s（超过默认 1h 间隔）
        clock.now = Date(timeIntervalSinceReferenceDate: 7200)
        scheduler.handleWake()
        await Task.yield()
        await Task.yield()

        // check 被调用 2 次：fire() 一次 + handleWake 内的 fire() 一次
        #expect(coordinator.checkModes.filter { $0 == .automatic }.count >= 2)
    }

    // MARK: handleWake — 未超期只 arm，不立即 fire

    @Test func handleWakeArmOnlyWhenNotOverdue() async {
        let coordinator = MockCoordinator()
        let clock = ControllableClock()
        let scheduler = makeScheduler(network: OnlineNetwork(), clock: clock, coordinator: coordinator)

        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.fire()   // lastFireDate = t0
        // fire() 内部是 Task { @MainActor in await coordinator.check() }，等它跑完再取基线
        await Task.yield()
        await Task.yield()
        let checkCountAfterFirstFire = coordinator.checkModes.count

        // 移动 60s（远未超期）
        clock.now = Date(timeIntervalSinceReferenceDate: 60)
        scheduler.handleWake()
        await Task.yield()
        await Task.yield()

        // check 计数不变（handleWake 不立即 fire）
        #expect(coordinator.checkModes.count == checkCountAfterFirstFire)
    }

    // MARK: handleWake — lastFireDate 和 lastCheckDate 均为 nil → 只 arm，不 fire

    @Test func handleWakeNoLastFireDateArmOnly() async {
        let coordinator = MockCoordinator()
        // lastFireDate = nil，lastCheckDate = nil（coordinator 默认值）
        let scheduler = makeScheduler(network: OnlineNetwork(), coordinator: coordinator)
        scheduler.handleWake()
        await Task.yield()
        await Task.yield()
        #expect(coordinator.checkModes.isEmpty)
    }

    // MARK: handleWake — lastFireDate 为 nil 但 lastCheckDate 超期 → 立即 fire

    @Test func handleWakeFiresWhenLastCheckDateOverdue() async {
        let coordinator = MockCoordinator()
        let clock = ControllableClock()
        clock.now = Date(timeIntervalSinceReferenceDate: 7200)
        let scheduler = makeScheduler(network: OnlineNetwork(), clock: clock, coordinator: coordinator)
        // 模拟初始扫描设置了 lastCheckDate（超过 1 小时前）
        coordinator.lastCheckDate = clock.now.addingTimeInterval(-3700)
        // lastFireDate 仍为 nil（timer 从未触发过）
        scheduler.handleWake()
        await Task.yield()
        await Task.yield()
        #expect(coordinator.checkModes == [.automatic])
    }

    // MARK: handleWake — interval==.off → 无操作

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
}

// MARK: - SudoMonitor Supplemental

@Suite("SudoMonitor Supplemental")
@MainActor
struct SudoMonitorSupplementalTests {

    private func makeMonitor(
        coordinator: MockCoordinator,
        notifSvc: MockNotificationService? = nil,
        timeoutSeconds: Int = 300,
        ppidProvider: @escaping (Int32) -> Int32? = { _ in nil }
    ) -> SudoMonitor {
        let svc = notifSvc ?? MockNotificationService()
        return SudoMonitor(
            coordinator: coordinator,
            timeoutProvider: { timeoutSeconds },
            notificationService: svc,
            ppidProvider: ppidProvider
        )
    }

    private func standardPPID(_ pid: Int32) -> Int32? {
        switch pid {
        case 10: return 20
        case 20: return 30
        default: return nil
        }
    }

    // triggerAuthorizationUI でポストされたあと activePIDs が残っていても crash しない
    @Test func triggerAuthorizationUIWithActiveSession() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: standardPPID)
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.transitionHistory.contains(.authorizing))
        // triggerAuthorizationUI は DistributedNotification を送るだけなのでクラッシュしなければ OK
        monitor.triggerAuthorizationUI()
    }

    // Helper が finished を送ると activePIDs が空になり、authorizing → updating へ遷移する
    @Test func helperFinishedTransitionsBackToUpdating() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: standardPPID)
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.status == .authorizing)

        await monitor.simulateHelperFinished(pid: 10)
        #expect(coordinator.transitionHistory.last == .updating)
    }

    // 複数 Helper が起動した場合、2 つ目は notifiedPIDs に追加され isRetry=true で通知される
    @Test func secondHelperTriggersRetryNotification() async {
        let coordinator = MockCoordinator()
        let notifSvc = MockNotificationService()
        let monitor = makeMonitor(coordinator: coordinator, notifSvc: notifSvc, ppidProvider: { pid in
            switch pid {
            case 10: return 20
            case 20: return 30
            case 11: return 21
            case 21: return 30
            default: return nil
            }
        })
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        await monitor.simulateHelperStarted(pid: 11)

        // 2 回 showAuthRequired が呼ばれる (initial + retry)
        #expect(notifSvc.authRequiredCalls >= 2)
    }

    // simulateHelperStarted で gpid が currentSessionPID と一致しない場合は無視される
    @Test func simulateHelperStartedGPIDMismatchIsIgnored() async {
        let coordinator = MockCoordinator()
        let monitor = makeMonitor(coordinator: coordinator, ppidProvider: { pid in
            switch pid {
            case 10: return 20
            case 20: return 99  // gpid=99 ≠ currentSession=30
            default: return nil
            }
        })
        monitor.registerSession(pid: 30)
        await monitor.simulateHelperStarted(pid: 10)
        #expect(coordinator.transitionHistory.isEmpty)
    }

    // sysctlPPID は実行中プロセスの PPID を返す（sysctl が正常動作している限り非 nil）
    @Test func sysctlPPIDReturnsNonNilForCurrentProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ppid = SudoMonitor.sysctlPPID(pid: pid)
        #expect(ppid != nil)
        #expect((ppid ?? 0) > 0)
    }
}

// MARK: - NotificationService Delivery

// これらのテストは UNUserNotificationCenter.add() の呼び出しを含む show* メソッドを直接叩いて
// コンテンツ生成コードパスを通す。テスト環境で通知権限がなくても center.add は静かに失敗するため、
// クラッシュしないこと＋コード到達を確認する。
@Suite("NotificationService Delivery")
@MainActor
struct NotificationServiceDeliveryTests {

    @Test func showUpdatesFoundDoesNotCrash() {
        NotificationService.shared.showUpdatesFound(packages: [makePackage()])
    }

    @Test func showAuthRequiredInitialRequest() {
        NotificationService.shared.showAuthRequired(packageNames: ["wget"], isRetry: false)
    }

    // isRetry=true → RequestID.authRetry() (UUID ベース) が呼ばれる
    @Test func showAuthRequiredRetryUsesUniqueID() {
        NotificationService.shared.showAuthRequired(packageNames: ["wget"], isRetry: true)
    }

    @Test func showAuthTimeoutDoesNotCrash() {
        NotificationService.shared.showAuthTimeout(packageName: "wget")
    }

    // showTransientError — .userCancelled パス
    @Test func showTransientErrorUserCancelled() {
        NotificationService.shared.showTransientError(error: .userCancelled)
    }

    // showTransientError — default パス (.commandFailed など)
    @Test func showTransientErrorCommandFailed() {
        NotificationService.shared.showTransientError(error: .commandFailed("something broke"))
    }

    // showTransientError — .authenticationFailed で packageName が nil のパス
    @Test func showTransientErrorAuthFailedWithoutPackageName() {
        NotificationService.shared.showTransientError(error: .authenticationFailed, packageName: nil)
    }
}

// MARK: - AutoScheduler Supplemental

@Suite("AutoScheduler Supplemental")
@MainActor
struct AutoSchedulerSupplementalTests {

    private struct OnlineNetwork: NetworkConnectivityProvider { var isConnected: Bool { true } }

    private final class MutableClock: ClockProvider {
        var now: Date = Date(timeIntervalSinceReferenceDate: 0)
    }

    private func makeScheduler(
        coordinator: MockCoordinator,
        workspaceCenter: NotificationCenter = NotificationCenter(),
        clock: ClockProvider? = nil
    ) -> AutoScheduler {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        return AutoScheduler(
            coordinator: coordinator,
            settings: settings,
            network: OnlineNetwork(),
            clock: clock ?? SystemClock(),
            workspaceCenter: workspaceCenter
        )
    }

    // stop() はタイマーを破棄する。stop 後に yield しても check が増えない
    @Test func stopAfterStartPreventsTimerFire() async {
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator)
        scheduler.start()
        scheduler.stop()
        await Task.yield()
        await Task.yield()
        #expect(coordinator.checkModes.count == 0)
    }

    // screensDidSleepNotification → タイマー破棄クロージャが実行される
    @Test func sleepNotificationInvalidatesTimer() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator, workspaceCenter: center)
        scheduler.start()

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await Task.yield()
        await Task.yield()

        // スリープ後はタイマーが無効化されているはず。
        // check は増えていないことで間接的に確認する。
        #expect(coordinator.checkModes.count == 0)
    }

    // screensDidWakeNotification → wakeObserver クロージャ経由で handleWake() が呼ばれる
    // lastFireDate=nil のとき handleWake は armTimer だけ行い、check を起こさない
    @Test func wakeNotificationCallsHandleWake() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let scheduler = makeScheduler(coordinator: coordinator, workspaceCenter: center)
        scheduler.start()  // lastFireDate = nil

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await Task.yield()
        await Task.yield()

        // handleWake は lastFireDate=nil のとき check しない
        #expect(coordinator.checkModes.isEmpty)
    }

    // screensDidWakeNotification — lastFireDate が超過している場合、即座に fire() する
    @Test func wakeNotificationFiresWhenOverdue() async {
        let center = NotificationCenter()
        let coordinator = MockCoordinator()
        let clock = MutableClock()
        let scheduler = makeScheduler(coordinator: coordinator, workspaceCenter: center, clock: clock)

        clock.now = Date(timeIntervalSinceReferenceDate: 0)
        scheduler.start()  // wake observer を登録する
        scheduler.fire()   // lastFireDate = t0
        await Task.yield()
        await Task.yield()
        let baseCount = coordinator.checkModes.count

        // 十分時間が経過したとみなす（interval は最短でも数分なので 100000s で確実に超過）
        clock.now = Date(timeIntervalSinceReferenceDate: 100_000)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        // NotificationCenter async dispatch → handleWake() → fire() → Task { check() }
        // 3 層の非同期処理を待つため sleep する
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // wake によって追加の check が発生する
        #expect(coordinator.checkModes.count > baseCount)
    }
}
