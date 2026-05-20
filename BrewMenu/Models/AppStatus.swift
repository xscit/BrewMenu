/// App lifecycle status: defines the full state machine from scanning through authorization to upgrade.
enum AppStatus: Equatable, CustomStringConvertible {
    case idle // Standby: system is up to date
    case scanning // Scanning: checking for Homebrew updates
    case outdated // Outdated: new versions detected
    case updating // Upgrading: executing sequential upgrade tasks
    case authorizing // Authorizing: waiting for user password or Touch ID
    case error(BrewError) // Error: path missing, network failure, or execution error

    var description: String {
        switch self {
        case .idle: "idle"
        case .scanning: "scanning"
        case .outdated: "outdated"
        case .updating: "updating"
        case .authorizing: "authorizing"
        case let .error(error): "error(\(error.userMessage))"
        }
    }
}
