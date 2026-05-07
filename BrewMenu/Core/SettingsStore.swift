import Foundation

/// Abstraction over persistent key-value storage, enabling testability.
protocol SettingsStore: Sendable {
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

// UserDefaults already implements all required methods — conformance is automatic.
extension UserDefaults: SettingsStore {}
