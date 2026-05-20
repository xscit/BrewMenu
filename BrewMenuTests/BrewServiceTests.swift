@testable import BrewMenu
import Foundation
import Testing

@Suite("BrewService")
@MainActor
struct BrewServiceTests {
    private func makeService(
        runner: MockBrewCommandRunner,
        brewURL: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    ) -> BrewService {
        BrewService(runner: runner, authService: AuthorizationService(bundle: .main), brewURL: brewURL)
    }

    // MARK: JSON 解析

    /// formulae 和 casks 均为空时，返回空数组而非错误
    @Test func parseEmptyListsReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON(outdatedJSON()).isEmpty)
    }

    /// formula 字段映射：name / installed_versions[0] / current_version
    @Test func parseSingleFormula() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(formulae: [("wget", "1.0", "1.1")]))
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "wget")
        #expect(pkgs[0].oldVersion == "1.0")
        #expect(pkgs[0].newVersion == "1.1")
    }

    /// cask 与 formula 的 JSON 结构相同，共用同一解析路径
    @Test func parseSingleCask() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(casks: [("firefox", "120.0", "121.0")]))
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "firefox")
        #expect(pkgs[0].newVersion == "121.0")
    }

    /// formulae 和 casks 合并为单一列表，顺序为 formulae 在前
    @Test func parseMixedFormulaeAndCasks() {
        let pkgs = BrewService.parseOutdatedJSON(outdatedJSON(
            formulae: [("wget", "1.0", "1.1"), ("git", "2.40", "2.41")],
            casks: [("iterm2", "3.4", "3.5")]
        ))
        #expect(pkgs.count == 3)
        #expect(Set(pkgs.map(\.name)) == ["wget", "git", "iterm2"])
    }

    /// brew 偶发输出非 JSON（如警告文本），不应抛出异常
    @Test func parseMalformedJSONReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON("not json at all").isEmpty)
    }

    /// 空字符串是 runner 队列耗尽时的默认返回值，需安全处理
    @Test func parseEmptyStringReturnsEmpty() {
        #expect(BrewService.parseOutdatedJSON("").isEmpty)
    }

    /// installed_versions 缺失时 fallback 为 "unknown"，保证 UI 不崩溃
    @Test func parseMissingInstalledVersionsDefaultsToUnknown() {
        let json = "{\"formulae\":[{\"name\":\"foo\",\"current_version\":\"2.0\"}],\"casks\":[]}"
        let pkgs = BrewService.parseOutdatedJSON(json)
        #expect(pkgs.count == 1)
        #expect(pkgs[0].oldVersion == "unknown")
    }

    /// BrewPackage 实现 Identifiable，id 就是包名，用于 SwiftUI List
    @Test func packageIdEqualsName() {
        let pkg = makePackage("wget")
        #expect(pkg.id == "wget")
    }

    // MARK: getOutdatedPackages

    /// brew 路径未找到时应提前失败，不应尝试执行任何命令
    @Test func getOutdatedBrewNotFoundWhenURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .getOutdatedPackages(shouldUpdate: false)
        #expect(result == .failure(.brewNotFound))
    }

    /// shouldUpdate=false 时只执行 brew outdated，不执行 brew update（手动刷新场景）
    @Test func getOutdatedSkipsUpdateCommandWhenFlagFalse() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]))
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false)
        #expect(runner.executedCommands.count == 1)
        guard case let .success(pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.count == 1)
        #expect(pkgs[0].name == "wget")
    }

    /// shouldUpdate=true 时先执行 brew update 再执行 brew outdated（自动/初始扫描场景）
    @Test func getOutdatedRunsUpdateCommandFirst() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue() // brew update → success
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")])) // brew outdated
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(runner.executedCommands.count == 2)
        guard case let .success(pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.count == 1)
    }

    /// brew update 断网时，不执行 brew outdated，直接返回网络错误
    @Test func getOutdatedPropagatesNetworkErrorFromUpdate() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "curl: (6) Could not resolve host", exitCode: 1)
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(result == .failure(.networkUnavailable))
        #expect(runner.executedCommands.count == 1)
    }

    /// brew outdated 命令本身断网时应正确传播错误
    @Test func getOutdatedNetworkErrorFromOutdatedCmd() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue() // update → success
        runner.enqueue(stderr: "curl: (6) Could not resolve host", exitCode: 1) // outdated → 断网
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: true)
        #expect(result == .failure(.networkUnavailable))
    }

    /// 无更新时返回空列表而非错误，调用方不需要特殊处理
    @Test func getOutdatedReturnsEmptyListWhenNothingOutdated() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON())
        let result = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false)
        guard case let .success(pkgs) = result else { Issue.record("Expected success"); return }
        #expect(pkgs.isEmpty)
    }

    /// --greedy 参数必须透传到 brew outdated 命令，漏传则 greedy 设置无效
    @Test func getOutdatedWithGreedyArgsForwardsToCommand() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON())
        _ = await makeService(runner: runner).getOutdatedPackages(shouldUpdate: false, greedyArgs: ["--greedy"])
        #expect(runner.executedCommands.first?.args.contains("--greedy") == true)
    }

    // MARK: checkIfPackageIsStillOutdated

    /// brew 路径缺失时，pre-check 保守地返回 true，让 upgrade 流程自行处理
    @Test func checkReturnsTrueWhenBrewURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    /// exit 0 表示 brew outdated 认为该包已是最新（外部已升级）
    @Test func checkReturnsFalseWhenExitCodeZero() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == false)
    }

    /// 非零退出且包名出现在 JSON 中，确认包仍需升级
    @Test func checkReturnsTrueWhenPackageInOutdatedJSON() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("wget", "1.0", "1.1")]), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    /// brew outdated 返回了其他包但不含 wget → wget 已是最新
    @Test func checkReturnsFalseWhenDifferentPackageInJSON() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(formulae: [("curl", "7.0", "8.0")]), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == false)
    }

    /// 非零退出但 JSON 为空 → 模糊场景，保守返回 true，让 upgrade 自行处理
    @Test func checkReturnsTrueOnEmptyJSONFallback() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stdout: outdatedJSON(), exitCode: 1)
        let result = await makeService(runner: runner).checkIfPackageIsStillOutdated(name: "wget")
        #expect(result == true)
    }

    // MARK: upgrade

    /// brew 路径缺失时，upgrade 应立即返回 brewNotFound 而非崩溃
    @Test func upgradeReturnsBrewNotFoundWhenURLNil() async {
        let result = await makeService(runner: MockBrewCommandRunner(), brewURL: nil)
            .upgrade(packages: [makePackage()])
        #expect(result == .failure(.brewNotFound))
    }

    /// 空包列表视为「已完成」，不应启动任何进程
    @Test func upgradeSucceedsImmediatelyForEmptyList() async {
        let runner = MockBrewCommandRunner()
        let result = await makeService(runner: runner).upgrade(packages: [])
        #expect(result == .success(true))
        #expect(runner.executedCommands.isEmpty)
    }

    /// 正常升级路径的基线
    @Test func upgradeSucceedsWithSinglePackage() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .success(true))
    }

    /// 3 次密码尝试全部错误，应返回 authenticationFailed 而非 userCancelled
    @Test func upgradeAuthenticationFailed() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: 3 incorrect password attempts", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.authenticationFailed))
    }

    /// 用户未输入密码直接关闭对话框，AskPass 以空密码退出
    @Test func upgradeUserCancelledEmptyPassword() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: no password was provided", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.userCancelled))
    }

    /// 输错一次密码后点击取消，两个错误信号同时出现，userCancelled 必须优先
    @Test func upgradeUserCancelledAfterWrongPassword() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "sudo: 1 incorrect password attempt\nsudo: a password is required", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.userCancelled))
    }

    /// brew 下载 cask 时断网，应返回 networkUnavailable
    @Test func upgradeNetworkError() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "curl: (6) Could not resolve host: ghcr.io", exitCode: 1)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        #expect(result == .failure(.networkUnavailable))
    }

    /// 非授权/网络以外的 brew 失败，错误信息透传给调用方
    @Test func upgradeCommandFailed() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "brew: some unexpected error", exitCode: 2)
        let result = await makeService(runner: runner).upgrade(packages: [makePackage()], greedyArgs: [], authTimeout: 300)
        guard case let .failure(err) = result, case let .commandFailed(msg) = err else {
            Issue.record("Expected commandFailed"); return
        }
        #expect(msg.contains("brew: some unexpected error"))
    }

    // MARK: cleanup

    /// 清理命令成功时返回 true
    @Test func cleanupSucceeds() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(exitCode: 0)
        let isSuccess = await makeService(runner: runner).cleanup(pruneDays: 0)
        #expect(isSuccess == true)
    }

    /// 清理命令失败时返回 false，不应抛出异常
    @Test func cleanupFails() async {
        let runner = MockBrewCommandRunner()
        runner.enqueue(stderr: "error", exitCode: 1)
        let isSuccess = await makeService(runner: runner).cleanup(pruneDays: 0)
        #expect(isSuccess == false)
    }
}
