import Foundation

/// Auto-check schedule interval presets.
enum CheckInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case custom = -1
    case oneHour = 3600
    case sixHours = 21600
    case twelveHours = 43200
    case twentyFourHours = 86400
    
    var id: Int { self.rawValue }
    
    /// User-facing description.
    var description: String {
        switch self {
        case .off: return String(localized: "opt_manual_only", table: "Settings")
        case .custom: return String(localized: "opt_custom", table: "Settings")
        case .oneHour: return String(localized: "opt_1_hour", table: "Settings")
        case .sixHours: return String(localized: "opt_6_hours", table: "Settings")
        case .twelveHours: return String(localized: "opt_12_hours", table: "Settings")
        case .twentyFourHours: return String(localized: "opt_24_hours", table: "Settings")
        }
    }
}
