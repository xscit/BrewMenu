@testable import BrewMenu
import Foundation
import Testing

@Suite("AuthorizationService")
struct AuthorizationServiceTests {
    private let service = AuthorizationService(bundle: .main)
    private let helperURL = URL(fileURLWithPath: "/tmp/FakeBrewMenuAskPass")

    /// SUDO_ASKPASS 是 sudo -A 模式的核心：指定弹出密码对话框的程序路径
    @Test func sudoAskpassIsSetToHelperPath() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [])
        #expect(env["SUDO_ASKPASS"] == helperURL.path)
    }

    // DISPLAY=:0 防止部分 Linux 环境下 AskPass 因无显示器而崩溃
    @Test func displayIsAlwaysSet() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [])
        #expect(env["DISPLAY"] == ":0")
    }

    /// AskPass 对话框标题需要知道是哪些包在请求权限
    @Test func packageInfoIsCommaSeparatedWhenNonEmpty() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: ["wget", "curl"])
        #expect(env["BREW_MENU_PACKAGE_INFO"] == "wget, curl")
    }

    /// 单个包时不带尾部逗号
    @Test func singlePackageInfoIsNameOnly() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: ["wget"])
        #expect(env["BREW_MENU_PACKAGE_INFO"] == "wget")
    }

    /// 无包时不应写入 BREW_MENU_PACKAGE_INFO，避免 AskPass 显示空列表
    @Test func packageInfoIsAbsentWhenPackagesEmpty() {
        let env = service.getAuthorizationEnvironment(askPassURL: helperURL, packages: [])
        #expect(env["BREW_MENU_PACKAGE_INFO"] == nil)
    }
}
