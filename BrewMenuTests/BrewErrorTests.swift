@testable import BrewMenu
import Testing

@Suite("BrewError")
struct BrewErrorTests {
    // MARK: parse — exit 0

    /// exit 0 表示命令成功，无论 stdout 内容如何都不应返回错误
    @Test func parseExitZeroReturnsNil() {
        #expect(BrewError.parse(stdout: "any output", stderr: "", exitCode: 0) == nil)
    }

    // MARK: parse — 网络错误

    /// brew update 依赖 curl 访问 GitHub CDN，断网时 curl 报错 (6)
    @Test func parseCurlFailureIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "curl: (6) Could not resolve host: ghcr.io", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    /// macOS 路由层错误，与 curl 错误是独立的网络不可达信号
    @Test func parseNoRouteToHostIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "No route to host: brew.sh", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    /// Linux 内核级别的网络不可达
    @Test func parseNetworkIsUnreachableIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "network is unreachable", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    /// DNS 解析失败，与 curl: (6) 是不同措辞但等价的网络信号
    @Test func parseCouldNotResolveHostIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "could not resolve host: api.github.com", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    /// brew update 连接 raw.githubusercontent.com 时的 HTTPS 失败措辞
    @Test func parseFailedToConnectIsNetworkError() {
        let err = BrewError.parse(stdout: "", stderr: "failed to connect to github.com", exitCode: 1)
        #expect(err == .networkUnavailable)
    }

    // MARK: parse — 用户取消（cancel 信号优先于 auth 失败）

    /// 用户直接点「取消」或关闭密码框，AskPass 以空密码退出
    @Test func parseNoPasswordProvidedIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: no password was provided", exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// sudo 未能找到 tty 或 askpass 程序，视为无法获取密码，等同于用户取消
    @Test func parseNoTTYPresentIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: no tty present and no askpass program specified", exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// 首次弹框用户未输入任何内容直接关闭时 sudo 的输出
    @Test func parsePasswordRequiredIsUserCancelled() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: a password is required", exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// sudo appends "a password is required" after a failed attempt — cancel 信号必须优先
    @Test func parseCancelAfterBadAttemptIsUserCancelled() {
        let stderr = "sudo: 1 incorrect password attempt\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// 输错 1 次后取消：两个信号同时出现，userCancelled 必须优先
    @Test func parseOneIncorrectAttemptThenCancelIsUserCancelled() {
        let stderr = "sudo: 1 incorrect password attempt\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// 输错 2 次后取消：同上
    @Test func parseTwoIncorrectAttemptsThenCancelIsUserCancelled() {
        let stderr = "sudo: 2 incorrect password attempts\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: 1)
        #expect(err == .userCancelled)
    }

    /// 进程被信号终止 (exitCode = -1) 时且包含取消标志，仍能识别出用户取消
    @Test func parseTerminatedProcessIsUserCancelled() {
        let stderr = "✔︎ Cask lab-sudo-c (1.1.0)\nsudo: no password was provided\nsudo: a password is required"
        let err = BrewError.parse(stdout: "", stderr: stderr, exitCode: -1)
        #expect(err == .userCancelled)
    }

    // MARK: parse — 认证失败

    /// sudo 连续 3 次拒绝后锁定，用户没有机会再次取消
    @Test func parseExhaustedRetriesIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: 3 incorrect password attempts", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    /// 输错 1 次但未取消（仅出现计数字，无取消信号）→ sudo 重试耗尽 → authenticationFailed
    @Test func parseOneIncorrectAttemptNoCancel() {
        let err = BrewError.parse(stdout: "", stderr: "sudo: 1 incorrect password attempt", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    /// PAM/Kerberos 层认证失败，与密码计数无关
    @Test func parseAuthCouldNotBeEstablishedIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "auth could not be established", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    /// macOS 密钥串/安全框处理过程通信失败
    @Test func parseConversationFailedIsAuthFailed() {
        let err = BrewError.parse(stdout: "", stderr: "conversation with the agent failed", exitCode: 1)
        #expect(err == .authenticationFailed)
    }

    // MARK: parse — 通用失败

    /// 非零退出且有 stderr → brew 执行失败，原始消息透传给调用方
    @Test func parseNonZeroWithStderrIsCommandFailed() {
        let err = BrewError.parse(stdout: "", stderr: "something went wrong", exitCode: 2)
        guard case let .commandFailed(msg) = err else { Issue.record("Expected commandFailed, got \(String(describing: err))"); return }
        #expect(msg == "something went wrong")
    }

    /// stderr 为空白时退码仍非零，fallback 用 exit code 构造消息，避免空错误
    @Test func parseNonZeroEmptyStderrContainsExitCode() {
        let err = BrewError.parse(stdout: "", stderr: "   ", exitCode: 42)
        guard case let .commandFailed(msg) = err else { Issue.record("Expected commandFailed"); return }
        #expect(msg.contains("42"))
    }

    // MARK: isFatal

    /// brewNotFound 是唯一的致命错误，会把 app 锁死在 .error 状态
    @Test func brewNotFoundIsFatal() {
        #expect(BrewError.brewNotFound.isFatal)
    }

    /// 网络错误是暂时性的，下一个周期自动重试，不应锁死 app
    @Test func networkUnavailableIsNotFatal() {
        #expect(!BrewError.networkUnavailable.isFatal)
    }

    /// 认证失败可重试，不应锁死 app
    @Test func authenticationFailedIsNotFatal() {
        #expect(!BrewError.authenticationFailed.isFatal)
    }

    /// userCancelled 没有锁死语义，错误对话框关闭后应可重试
    @Test func userCancelledIsNotFatal() {
        #expect(!BrewError.userCancelled.isFatal)
    }

    /// commandFailed 是可自此恢复的运行时错误，不锁死 app
    @Test func commandFailedIsNotFatal() {
        #expect(!BrewError.commandFailed("x").isFatal)
    }

    // MARK: isNetworkError

    @Test func networkUnavailableIsNetworkError() {
        #expect(BrewError.networkUnavailable.isNetworkError)
    }

    /// brew 命令失败与网络无关，不应触发静默跳过逻辑
    @Test func commandFailedIsNotNetworkError() {
        #expect(!BrewError.commandFailed("oops").isNetworkError)
    }

    /// 用户取消应被当作「跳过」而非网络不可达
    @Test func userCancelledIsNotNetworkError() {
        #expect(!BrewError.userCancelled.isNetworkError)
    }

    /// 认证失败与网络无关，不应触发静默跳过
    @Test func authFailedIsNotNetworkError() {
        #expect(!BrewError.authenticationFailed.isNetworkError)
    }

    /// brew 路径缺失与网络无关
    @Test func brewNotFoundIsNotNetworkError() {
        #expect(!BrewError.brewNotFound.isNetworkError)
    }

    // MARK: isUserCancelled

    /// isUserCancelled 用于区分「跳过」和「失败」的通知措辞
    @Test func userCancelledIsUserCancelled() {
        #expect(BrewError.userCancelled.isUserCancelled)
    }

    /// brew 路径缺失是配置问题，和用户行为无关
    @Test func brewNotFoundIsNotUserCancelled() {
        #expect(!BrewError.brewNotFound.isUserCancelled)
    }

    /// 认证失败是密码错误，不是用户主动放弃
    @Test func authFailedIsNotUserCancelled() {
        #expect(!BrewError.authenticationFailed.isUserCancelled)
    }

    /// 断网与用户意图无关
    @Test func networkUnavailableIsNotUserCancelled() {
        #expect(!BrewError.networkUnavailable.isUserCancelled)
    }

    /// brew 命令失败与用户操作无关
    @Test func commandFailedIsNotUserCancelled() {
        #expect(!BrewError.commandFailed("x").isUserCancelled)
    }

    // MARK: userMessage / technicalDetail

    /// commandFailed.userMessage 是通用文字，technicalDetail 存储原始 stderr
    @Test func userMessageCommandFailedIsGeneric() {
        #expect(BrewError.commandFailed("bad output").userMessage == "Command failed")
        #expect(BrewError.commandFailed("bad output").technicalDetail == "bad output")
    }

    /// 其他 case 的 technicalDetail 为 nil
    @Test func technicalDetailIsNilForNonCommandFailed() {
        #expect(BrewError.networkUnavailable.technicalDetail == nil)
        #expect(BrewError.authenticationFailed.technicalDetail == nil)
    }
}
