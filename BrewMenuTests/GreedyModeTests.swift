@testable import BrewMenu
import Testing

@Suite("GreedyMode")
struct GreedyModeTests {
    /// 每个 GreedyMode 对应固定的 brew CLI 参数，参数错误会导致 greedy 设置无效
    @Test(arguments: [
        (GreedyMode.disabled, [String]()),
        (GreedyMode.all, ["--greedy"]),
        (GreedyMode.autoUpdates, ["--greedy-auto-updates"]),
        (GreedyMode.latest, ["--greedy-latest"]),
    ])
    func brewArgs(mode: GreedyMode, expected: [String]) {
        #expect(mode.args == expected)
    }

    /// Identifiable 要求 id 唯一且与 rawValue 一致，确保 Picker 选中状态正确
    @Test(arguments: GreedyMode.allCases)
    func idMatchesRawValue(mode: GreedyMode) {
        #expect(mode.id == mode.rawValue)
    }

    /// description 用于 UI 展示；非 disabled 的 case 直接显示 CLI flag 字符串
    @Test(arguments: [
        (GreedyMode.all, "--greedy"),
        (GreedyMode.autoUpdates, "--greedy-auto-updates"),
        (GreedyMode.latest, "--greedy-latest")
    ])
    func descriptionMatchesFlag(mode: GreedyMode, expected: String) {
        #expect(mode.description == expected)
    }

    /// disabled 的 description 是本地化字符串（非空）
    @Test func disabledDescriptionIsNonEmpty() {
        #expect(!GreedyMode.disabled.description.isEmpty)
    }
}
