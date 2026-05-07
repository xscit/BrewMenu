import Foundation

/// Homebrew error cases: covers path-missing, network failure, lock conflicts, and user cancellation.
enum BrewError: Error, Equatable {
    case brewNotFound
    case networkUnavailable
    case userCancelled
    case authenticationFailed
    case commandFailed(String)
    
    /// Whether this error should lock the app into the `.error` state.
    var isFatal: Bool {
        switch self {
        case .brewNotFound: return true
        default: return false
        }
    }

    var isNetworkError: Bool {
        if case .networkUnavailable = self { return true }
        return false
    }
    
    /// Whether the user cancelled during the authorization phase.
    var isUserCancelled: Bool {
        if case .userCancelled = self { return true }
        return false
    }
    
    /// User-facing error description.
    var userMessage: String {
        switch self {
        case .brewNotFound: return String(localized: "err_brew_not_found", table: "Errors")
        case .networkUnavailable: return String(localized: "err_network_unavailable", table: "Errors")
        case .userCancelled: return String(localized: "err_user_cancelled", table: "Errors")
        case .authenticationFailed: return String(localized: "err_auth_failed", table: "Errors")
        case .commandFailed(let reason): return reason
        }
    }
    
    /// Parse stdout/stderr/exitCode into a typed error (nil means success).
    static func parse(stdout: String, stderr: String, exitCode: Int32) -> BrewError? {
        if exitCode == 0 { return nil }
        
        let combined = (stderr + stdout).lowercased()

        // Detect network unavailability (curl/git failures from brew update)
        if combined.contains("curl: (") ||
           combined.contains("network is unreachable") ||
           combined.contains("could not resolve host") ||
           combined.contains("failed to connect") ||
           combined.contains("no route to host") {
            return .networkUnavailable
        }

        // Detect complete authentication failure (PAM/Kerberos-level errors, not password count).
        if combined.contains("auth could not be established") ||
           combined.contains("conversation with the agent failed") {
            return .authenticationFailed
        }

        // 1. Check if the user ultimately cancelled. If they cancelled on the 2nd
        // or 3rd try, sudo will append "a password is required". We must check this
        // FIRST, so that an ultimate cancellation isn't misclassified as an auth failure.
        if exitCode == 1 {
            let stderrLower = stderr.lowercased()
            if stderrLower.contains("no password was provided") ||
               stderrLower.contains("no password was supplied") ||
               stderrLower.contains("a password is required") ||
               stderrLower.contains("no tty present and no askpass program specified") {
                return .userCancelled
            }
            
            // 2. If it wasn't cancelled, but contains incorrect attempts, it means
            // the user exhausted their 3 retries and was locked out by sudo.
            if stderrLower.contains("incorrect password attempt") {
                return .authenticationFailed
            }
        }
        
        // All other errors: return the raw stderr content
        let rawError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawError.isEmpty {
            return .commandFailed(rawError)
        }
        
        return .commandFailed("Exit code \(exitCode)")
    }
}
