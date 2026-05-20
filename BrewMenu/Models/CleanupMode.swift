import Foundation

/// When to run `brew cleanup` automatically.
enum CleanupSchedule: String, CaseIterable, Identifiable {
    case disabled
    case afterUpgrade
    case everyNDays

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .disabled: String(localized: "opt_none", table: "Settings")
        case .afterUpgrade: String(localized: "opt_after_upgrade", table: "Settings")
        case .everyNDays: String(localized: "opt_every_n_days", table: "Settings")
        }
    }
}
