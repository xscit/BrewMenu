import Foundation

/// Homebrew Cask greedy upgrade mode.
enum GreedyMode: String, CaseIterable, Identifiable {
    case disabled = "none"
    case all
    case autoUpdates
    case latest

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .disabled: String(localized: "opt_none", table: "Settings")
        case .all: "--greedy"
        case .autoUpdates: "--greedy-auto-updates"
        case .latest: "--greedy-latest"
        }
    }

    /// Convert to brew command arguments.
    var args: [String] {
        switch self {
        case .disabled: []
        case .all: ["--greedy"]
        case .autoUpdates: ["--greedy-auto-updates"]
        case .latest: ["--greedy-latest"]
        }
    }
}
