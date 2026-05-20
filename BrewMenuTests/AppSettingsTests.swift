@testable import BrewMenu
import Foundation
import Testing

@Suite("AppSettings")
@MainActor
struct AppSettingsTests {
    // MARK: 默认值

    /// 全新安装后未写入任何值，读取默认配置时不应崩溃
    @Test func defaultCheckIntervalIsOneHour() {
        #expect(AppSettings(store: MockSettingsStore()).checkInterval == .oneHour)
    }

    /// custom 模式下未配置时使用合理默认值，避免极端间隔
    @Test func defaultCustomIntervalIsOneHour() {
        #expect(AppSettings(store: MockSettingsStore()).customCheckInterval == DefaultsKey.defaultCustomIntervalSeconds)
    }

    /// 自动升级默认关闭，防止用户意外触发静默升级
    @Test func defaultAutoUpgradeIsDisabled() {
        #expect(!AppSettings(store: MockSettingsStore()).isAutoUpgradeEnabled)
    }

    /// greedy 模式默认关闭，避免升级自动更新类 cask
    @Test func defaultGreedyModeIsDisabled() {
        #expect(AppSettings(store: MockSettingsStore()).greedyMode == .disabled)
    }

    /// 授权超时默认 5 分钟
    @Test func defaultAuthTimeoutIs300() {
        #expect(AppSettings(store: MockSettingsStore()).authTimeout == DefaultsKey.defaultAuthTimeoutSeconds)
    }

    /// 新安装时排除列表为空
    @Test func defaultPinnedPackagesIsEmpty() {
        #expect(AppSettings(store: MockSettingsStore()).pinnedPackages.isEmpty)
    }

    // MARK: currentIntervalSeconds

    /// 预设模式直接用 rawValue（秒数），无需换算
    @Test func currentIntervalSecondsForPreset() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.checkInterval = .sixHours
        #expect(settings.currentIntervalSeconds == Double(CheckInterval.sixHours.rawValue))
    }

    /// custom 模式读取 customCheckInterval 而非 rawValue
    @Test func currentIntervalSecondsForCustom() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.checkInterval = .custom
        settings.customCheckInterval = 7200
        #expect(settings.currentIntervalSeconds == 7200.0)
    }

    // MARK: 持久化

    /// 设置写入必须立即落地到 SettingsStore，保证 app 重启后恢复
    @Test func checkIntervalPersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).checkInterval = .twentyFourHours
        #expect(store.integer(forKey: DefaultsKey.checkInterval) == CheckInterval.twentyFourHours.rawValue)
    }

    /// Bool 类型持久化路径
    @Test func autoUpgradePersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).isAutoUpgradeEnabled = true
        #expect(store.bool(forKey: DefaultsKey.isAutoUpgradeEnabled) == true)
    }

    /// GreedyMode 存储为 rawValue 字符串，与 UserDefaults 的 string(forKey:) 对齐
    @Test func greedyModePersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).greedyMode = .all
        #expect(store.string(forKey: DefaultsKey.greedyMode) == GreedyMode.all.rawValue)
    }

    /// Int 类型持久化路径
    @Test func authTimeoutPersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).authTimeout = 120
        #expect(store.integer(forKey: DefaultsKey.authTimeout) == 120)
    }

    // MARK: 范围限制

    /// 低于最小值（60s）的输入必须被截断，防止 Timer 过于频繁
    @Test func customIntervalClampedToMinimum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.customCheckInterval = 10
        #expect(settings.customCheckInterval == DefaultsKey.minimumCustomIntervalSeconds)
    }

    /// 高于最大值（7天）的输入必须被截断，防止用户意外设置永不检查
    @Test func customIntervalClampedToMaximum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.customCheckInterval = 999_999_999
        #expect(settings.customCheckInterval == DefaultsKey.maximumCustomIntervalSeconds)
    }

    // MARK: 从 Store 恢复

    /// 模拟 app 重启：从已填充的 Store 初始化，验证所有字段正确还原
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

    /// app 重启后从 Store 正确恢复排除列表
    @Test func pinnedPackagesRestoredFromStore() {
        let store = MockSettingsStore()
        store.set(["wget", "curl"], forKey: DefaultsKey.pinnedPackages)
        let settings = AppSettings(store: store)
        #expect(settings.pinnedPackages == ["wget", "curl"])
    }

    // MARK: pinnedPackages 持久化

    /// 插入一个包后立即写入 Store
    @Test func pinnedPackagesPersistsToStore() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.pinnedPackages.insert("wget")
        let stored = store.object(forKey: DefaultsKey.pinnedPackages) as? [String]
        #expect(stored?.contains("wget") == true)
    }

    /// 多个包均写入 Store，顺序无关（Set → [String] 不保证顺序）
    @Test func multiplePinnedPackagesAllPersisted() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.pinnedPackages = ["wget", "curl", "git"]
        let stored = Set(store.object(forKey: DefaultsKey.pinnedPackages) as? [String] ?? [])
        #expect(stored == ["wget", "curl", "git"])
    }

    /// removeAll() 立即将空数组写入 Store，防止重启后残留
    @Test func clearingPinnedPackagesPersistsEmptyList() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.pinnedPackages = ["wget"]
        settings.pinnedPackages.removeAll()
        let stored = store.object(forKey: DefaultsKey.pinnedPackages) as? [String]
        #expect(stored?.isEmpty == true)
    }

    /// 移除单个包后其余包保持不变
    @Test func removingOnePinnedPackageRetainsOthers() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.pinnedPackages = ["wget", "curl"]
        settings.pinnedPackages.remove("wget")
        #expect(!settings.pinnedPackages.contains("wget"))
        #expect(settings.pinnedPackages.contains("curl"))
    }

    // MARK: cleanupSchedule 持久化

    /// cleanupSchedule 默认为 disabled
    @Test func defaultCleanupScheduleIsDisabled() {
        #expect(AppSettings(store: MockSettingsStore()).cleanupSchedule == .disabled)
    }

    /// cleanupSchedule 写入 Store 时使用 rawValue
    @Test func cleanupSchedulePersistsToStore() {
        let store = MockSettingsStore()
        AppSettings(store: store).cleanupSchedule = .afterUpgrade
        #expect(store.string(forKey: DefaultsKey.cleanupSchedule) == CleanupSchedule.afterUpgrade.rawValue)
    }

    /// cleanupSchedule 从 Store 正确恢复
    @Test func cleanupScheduleRestoredFromStore() {
        let store = MockSettingsStore()
        store.set(CleanupSchedule.everyNDays.rawValue, forKey: DefaultsKey.cleanupSchedule)
        #expect(AppSettings(store: store).cleanupSchedule == .everyNDays)
    }

    // MARK: cleanupIntervalDays 范围限制

    /// 低于最小值（1天）时截断
    @Test func cleanupIntervalDaysClampedToMinimum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.cleanupIntervalDays = 0
        #expect(settings.cleanupIntervalDays == DefaultsKey.minimumCleanupIntervalDays)
    }

    /// 高于最大值（365天）时截断
    @Test func cleanupIntervalDaysClampedToMaximum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.cleanupIntervalDays = 9999
        #expect(settings.cleanupIntervalDays == DefaultsKey.maximumCleanupIntervalDays)
    }

    /// 有效值直接写入 Store
    @Test func cleanupIntervalDaysPersistsValidValue() {
        let store = MockSettingsStore()
        AppSettings(store: store).cleanupIntervalDays = 14
        #expect(store.integer(forKey: DefaultsKey.cleanupIntervalDays) == 14)
    }

    // MARK: cleanupPruneDays 范围限制

    /// 高于最大值（365天）时截断
    @Test func cleanupPruneDaysClampedToMaximum() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.cleanupPruneDays = 9999
        #expect(settings.cleanupPruneDays == DefaultsKey.maximumCleanupPruneDays)
    }

    /// 0 是有效值（表示 --prune=all），不应被截断
    @Test func cleanupPruneDaysZeroIsValid() {
        let settings = AppSettings(store: MockSettingsStore())
        settings.cleanupPruneDays = 0
        #expect(settings.cleanupPruneDays == 0)
    }

    /// 有效值直接写入 Store
    @Test func cleanupPruneDaysPersistsValidValue() {
        let store = MockSettingsStore()
        AppSettings(store: store).cleanupPruneDays = 30
        #expect(store.integer(forKey: DefaultsKey.cleanupPruneDays) == 30)
    }

    // MARK: lastCleanupDate 持久化

    /// lastCleanupDate 写入并从 Store 恢复
    @Test func lastCleanupDatePersistsToStore() {
        let store = MockSettingsStore()
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        AppSettings(store: store).lastCleanupDate = date
        #expect(store.object(forKey: DefaultsKey.lastCleanupDate) as? Date == date)
    }

    /// lastCleanupDate nil 时写入 nil
    @Test func lastCleanupDateNilPersistsNil() {
        let store = MockSettingsStore()
        let settings = AppSettings(store: store)
        settings.lastCleanupDate = Date()
        settings.lastCleanupDate = nil
        #expect(store.object(forKey: DefaultsKey.lastCleanupDate) == nil)
    }
}
