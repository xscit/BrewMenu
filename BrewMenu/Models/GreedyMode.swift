import Foundation

/// Homebrew Cask greedy upgrade mode.
enum GreedyMode: String, CaseIterable, Identifiable {
    case disabled = "none"
    case all = "all"
    case autoUpdates = "autoUpdates"
    case latest = "latest"

    var id: String { self.rawValue }

    var description: String {
        switch self {
        case .disabled: return String(localized: "opt_none", table: "Settings")
        case .all: return "--greedy"
        case .autoUpdates: return "--greedy-auto-updates"
        case .latest: return "--greedy-latest"
        }
    }

    /// Convert to brew command arguments.
    var args: [String] {
        switch self {
        case .disabled: return []
        case .all: return ["--greedy"]
        case .autoUpdates: return ["--greedy-auto-updates"]
        case .latest: return ["--greedy-latest"]
        }
    }
}
