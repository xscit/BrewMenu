import Foundation

/// Homebrew cleanup mode after upgrade.
enum CleanupMode: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case pruneAll = "pruneAll"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .disabled: return String(localized: "opt_none", table: "Settings")
        case .pruneAll: return "--prune=all"
        }
    }

    var args: [String] {
        switch self {
        case .disabled: return []
        case .pruneAll: return ["--prune=all"]
        }
    }
}
