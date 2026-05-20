@testable import BrewMenu
import Testing

@Suite("CleanupSchedule")
struct CleanupScheduleTests {
    /// id は rawValue と一致し、Picker の選択状態が正しく動作する
    @Test(arguments: CleanupSchedule.allCases)
    func idMatchesRawValue(schedule: CleanupSchedule) {
        #expect(schedule.id == schedule.rawValue)
    }

    /// description は空でなく UI 表示に使える
    @Test(arguments: CleanupSchedule.allCases)
    func descriptionIsNonEmpty(schedule: CleanupSchedule) {
        #expect(!schedule.description.isEmpty)
    }

    /// rawValue から正しく復元できること（Store への保存 → 読み出しのラウンドトリップ）
    @Test(arguments: CleanupSchedule.allCases)
    func rawValueRoundTrip(schedule: CleanupSchedule) {
        #expect(CleanupSchedule(rawValue: schedule.rawValue) == schedule)
    }

    /// allCases に全 case が含まれ、重複がない
    @Test func allCasesAreUnique() {
        let ids = CleanupSchedule.allCases.map(\.id)
        #expect(Set(ids).count == CleanupSchedule.allCases.count)
    }
}
