import Foundation
import UserNotifications
import os

// MARK: - Protocol

@MainActor
protocol NotificationServiceProtocol: AnyObject {
    var onAuthorizeActionTapped: (() -> Void)? { get set }
    func requestAuthorization()
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String], externalSuccessNames: [String])
    func showUpdatesFound(packages: [BrewPackage])
    func showAuthRequired(packageNames: [String], isRetry: Bool)
    func showAuthTimeout(packageName: String)
    func showTransientError(error: BrewError, packageName: String?)
}

/// Notification service: manages system notifications, categories, and upgrade result display.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationServiceProtocol {
    static let shared = NotificationService()

    /// Callback fired when the user taps the "Authorize" action on an auth notification.
    var onAuthorizeActionTapped: (() -> Void)?

    // MARK: - Identifiers

    private enum Category {
        static let authRequired = "AUTH_REQUIRED"
    }

    private enum Action {
        static let authorize = "AUTHORIZE"
    }

    private enum RequestID {
        static let updatesFound = "UPDATES_FOUND"
        static let authTrigger  = "AUTH_TRIGGER"
        static func authRetry()  -> String { "AUTH_RETRY_\(UUID().uuidString)" }
        static func error()      -> String { "ERROR_\(UUID().uuidString)" }
    }

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Request notification authorization and register categories.
    func requestAuthorization() {
        let authorizeAction = UNNotificationAction(
            identifier: Action.authorize,
            title: String(localized: "action_authorize", table: "Notifications"),
            // `.foreground` raises the app to the front so the user lands in the menu immediately.
            options: [.foreground]
        )
        let authCategory = UNNotificationCategory(
            identifier: Category.authRequired,
            actions: [authorizeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([authCategory])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.core.error("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.core.notice("Notification authorization denied by user.")
            }
        }
    }

    /// Post an upgrade result summary notification.
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String] = [], externalSuccessNames: [String] = []) {
        let content = UNMutableNotificationContent()
        let result = upgradeResultContent(upgraded: upgraded, success: success, requestedNames: requestedNames, skippedNames: skippedNames, externalSuccessNames: externalSuccessNames)
        content.title = result.title
        content.body = result.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// Build the title and body for an upgrade result notification.
    /// Separated from posting so the content logic can be unit-tested independently.
    func upgradeResultContent(
        upgraded: [BrewPackage],
        success: Bool,
        requestedNames: [String],
        skippedNames: [String],
        externalSuccessNames: [String]
    ) -> (title: String, body: String) {
        // Deduplicate: exclude packages already upgraded externally
        let externalNamesSet = Set(externalSuccessNames)
        let filteredUpgraded = upgraded.filter { !externalNamesSet.contains($0.name) }

        let upgradedNamesSet = Set(filteredUpgraded.map { $0.name })
        let skippedNamesSet = Set(skippedNames)
        let failedNames = requestedNames.filter {
            !upgradedNamesSet.contains($0) &&
            !externalNamesSet.contains($0) &&
            !skippedNamesSet.contains($0)
        }

        if filteredUpgraded.isEmpty && externalSuccessNames.isEmpty && skippedNames.isEmpty {
            if !success && !failedNames.isEmpty {
                return (
                    String(localized: "title_upgrade_failed", table: "Notifications"),
                    String(localized: "body_upgrade_failed \(failedNames.joined(separator: ", "))", table: "Notifications")
                )
            } else {
                return (
                    String(localized: "title_brew_ready", table: "Notifications"),
                    String(localized: "body_brew_ready", table: "Notifications")
                )
            }
        } else {
            let title = success
                ? String(localized: "title_brew_updated", table: "Notifications")
                : String(localized: "title_partial_upgrade", table: "Notifications")

            // Emoji legend — ✅: success, ℹ️: externally synced, ⏭️: skipped, ❌: failed
            var lines: [String] = []
            for pkg in filteredUpgraded {
                lines.append(String(localized: "line_package_success \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", table: "Notifications"))
            }
            for name in externalSuccessNames {
                lines.append(String(localized: "line_package_external \(name)", table: "Notifications"))
            }
            for name in skippedNames {
                lines.append(String(localized: "line_package_skipped \(name)", table: "Notifications"))
            }
            if !failedNames.isEmpty {
                lines.append(String(localized: "line_package_failed \(failedNames.joined(separator: ", "))", table: "Notifications"))
            }

            return (title, lines.joined(separator: "\n"))
        }
    }

    /// Notify the user that updates are available.
    func showUpdatesFound(packages: [BrewPackage]) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "title_updates_available", table: "Notifications")
        content.body = String(localized: "body_updates_found \(packages.count) \(packages.map { $0.name }.joined(separator: ", "))", table: "Notifications")
        content.sound = .default

        let request = UNNotificationRequest(identifier: RequestID.updatesFound, content: content, trigger: nil)
        center.add(request)
    }

    /// Notify the user that authorization is required.
    func showAuthRequired(packageNames: [String], isRetry: Bool = false) {
        let content = UNMutableNotificationContent()

        if isRetry {
            content.title = String(localized: "title_auth_failed", table: "Notifications")
            content.body = String(localized: "body_auth_failed_retry \(packageNames.joined(separator: ", "))", table: "Notifications")
        } else {
            content.title = String(localized: "title_auth_required", table: "Notifications")
            content.body = String(localized: "body_auth_required \(packageNames.joined(separator: ", "))", table: "Notifications")
        }

        content.sound = .default
        content.categoryIdentifier = Category.authRequired

        // Use unique ID for retries so they appear as fresh banners
        let requestID = isRetry ? RequestID.authRetry() : RequestID.authTrigger
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        center.add(request)
    }

    /// Notify the user that authorization timed out.
    func showAuthTimeout(packageName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "title_auth_timeout", table: "Notifications")
        content.body = String(localized: "body_auth_timeout \(packageName)", table: "Notifications")
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: RequestID.error(), content: content, trigger: nil)
        center.add(request)
    }

    /// Post a transient (non-fatal) error notification.
    func showTransientError(error: BrewError, packageName: String? = nil) {
        let content = UNMutableNotificationContent()

        switch error {
        case .authenticationFailed:
            content.title = String(localized: "title_auth_failed", table: "Notifications")
            if let name = packageName {
                content.body = String(localized: "body_transient_auth_failed \(name)", table: "Notifications")
            } else {
                content.body = String(localized: "body_transient_warning \(error.userMessage)", table: "Notifications")
            }
        case .userCancelled:
            content.title = String(localized: "title_operation_cancelled", table: "Notifications")
            content.body = String(localized: "body_transient_cancelled \(error.userMessage)", table: "Notifications")
        default:
            content.title = String(localized: "title_command_failed", table: "Notifications")
            content.body = String(localized: "body_transient_error \(error.userMessage)", table: "Notifications")
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: RequestID.error(), content: content, trigger: nil)
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Action.authorize {
            Task { @MainActor in
                self.onAuthorizeActionTapped?()
            }
        }
        completionHandler()
    }
}
