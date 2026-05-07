import Foundation

/// Value type encapsulating all parameters for a single Homebrew command execution.
/// Replaces the previous 8-parameter `execute()` signature with a structured, self-documenting type.
struct BrewCommand: Sendable {
    let executable: URL
    let args: [String]
    var packages: [String] = []
    
    /// Additional environment variables merged into the process env (e.g., auth-related vars).
    var additionalEnvironment: [String: String] = [:]
    
    /// Callback invoked with the process PID immediately after launch.
    var onPID: (@Sendable (Int32) -> Void)?
}
