import Foundation

/// App lifecycle status: defines the full state machine from scanning through authorization to upgrade.
enum AppStatus: Equatable, Sendable, CustomStringConvertible {
    case idle           // Standby: system is up to date
    case scanning       // Scanning: checking for Homebrew updates
    case outdated       // Outdated: new versions detected
    case updating       // Upgrading: executing sequential upgrade tasks
    case authorizing    // Authorizing: waiting for user password or Touch ID
    case error(BrewError)   // Error: path missing, network failure, or execution error
    
    var description: String {
        switch self {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .outdated: return "outdated"
        case .updating: return "updating"
        case .authorizing: return "authorizing"
        case .error(let e): return "error(\(e.userMessage))"
        }
    }
}
