import Foundation
import UserNotifications

// MARK: - Protocol

@MainActor
protocol NotificationServiceProtocol: AnyObject {
    var onAuthorizeActionTapped: (() -> Void)? { get set }
    func requestAuthorization()
    func showNoUpdatesFound()
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String], externalSuccessNames: [String], failedErrors: [String: String])
    func showUpdatesFound(packages: [BrewPackage], willAutoUpgrade: Bool)
    func showAuthRequired(packageNames: [String], isRetry: Bool)
    func showAuthTimeout(packageName: String)
    func showTransientError(error: BrewError, packageName: String?)
    func showBrewNotFound()
}

/// Notification service: manages system notifications, categories, and upgrade result display.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationServiceProtocol {
    static let shared = NotificationService()

    /// Callback fired when the user taps the "Authorize" action on an auth notification.
    var onAuthorizeActionTapped: (() -> Void)?

    /// Test hook: called with every request before it is submitted to UNUserNotificationCenter.
    /// Set this in unit tests to capture and inspect outgoing notifications.
    var onRequestScheduled: ((UNNotificationRequest) -> Void)?

    /// Injected settings used to gate notifications by user preference.
    weak var settings: AppSettings?

    // MARK: - Identifiers

    private enum Category {
        static let authRequired = "AUTH_REQUIRED"
    }

    private enum Action {
        static let authorize = "AUTHORIZE"
    }

    enum RequestID {
        static let updatesFound = "UPDATES_FOUND"
        static let noUpdatesFound = "NO_UPDATES_FOUND"
        static let authTrigger = "AUTH_TRIGGER"
        static let authRetry = "AUTH_RETRY"
        static let brewNotFound = "BREW_NOT_FOUND"
        static func error() -> String {
            "ERROR_\(UUID().uuidString)"
        }
    }

    private let center = UNUserNotificationCenter.current()

    override private init() {
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

    // MARK: - No Updates

    /// Notify the user that a scan found no updates.
    func showNoUpdatesFound() {
        guard settings?.notifyOnScanResults != false else { return }
        let result = noUpdatesFoundContent()
        schedule(title: result.title, body: result.body, identifier: RequestID.noUpdatesFound)
    }

    func noUpdatesFoundContent() -> (title: String, body: String) {
        (
            String(localized: "title_brew_ready", table: "Notifications"),
            String(localized: "body_brew_ready", table: "Notifications")
        )
    }

    // MARK: - Updates Found

    /// Notify the user that updates are available or that an auto-upgrade is starting.
    func showUpdatesFound(packages: [BrewPackage], willAutoUpgrade: Bool = false) {
        guard settings?.notifyOnScanResults != false else { return }
        let result = updatesFoundContent(packages: packages, willAutoUpgrade: willAutoUpgrade)
        schedule(title: result.title, body: result.body, identifier: RequestID.updatesFound)
    }

    func updatesFoundContent(packages: [BrewPackage], willAutoUpgrade: Bool) -> (title: String, body: String) {
        let names = packages.map(\.name).joined(separator: ", ")
        if willAutoUpgrade {
            return (
                String(localized: "title_upgrading", table: "Notifications"),
                String(localized: "body_upgrading \(packages.count) \(names)", table: "Notifications")
            )
        } else {
            return (
                String(localized: "title_updates_available", table: "Notifications"),
                String(localized: "body_updates_found \(packages.count) \(names)", table: "Notifications")
            )
        }
    }

    // MARK: - Upgrade Result

    /// Post an upgrade result summary notification.
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String] = [], externalSuccessNames: [String] = [], failedErrors: [String: String] = [:]) {
        guard settings?.notifyOnUpgradeResult != false else { return }
        let result = upgradeResultContent(upgraded: upgraded, success: success, requestedNames: requestedNames, skippedNames: skippedNames, externalSuccessNames: externalSuccessNames, failedErrors: failedErrors)
        schedule(title: result.title, body: result.body, identifier: UUID().uuidString)
    }

    /// Build the title and body for an upgrade result notification.
    /// Separated from posting so the content logic can be unit-tested independently.
    func upgradeResultContent(
        upgraded: [BrewPackage],
        success: Bool,
        requestedNames: [String],
        skippedNames: [String],
        externalSuccessNames: [String],
        failedErrors: [String: String] = [:]
    ) -> (title: String, body: String) {
        // Deduplicate: exclude packages already upgraded externally
        let externalNamesSet = Set(externalSuccessNames)
        let filteredUpgraded = upgraded.filter { !externalNamesSet.contains($0.name) }

        let upgradedNamesSet = Set(filteredUpgraded.map(\.name))
        let skippedNamesSet = Set(skippedNames)
        let failedNames = requestedNames.filter {
            !upgradedNamesSet.contains($0) &&
                !externalNamesSet.contains($0) &&
                !skippedNamesSet.contains($0)
        }

        if filteredUpgraded.isEmpty, externalSuccessNames.isEmpty, skippedNames.isEmpty, failedNames.isEmpty {
            return (
                String(localized: "title_brew_ready", table: "Notifications"),
                String(localized: "body_brew_ready", table: "Notifications")
            )
        }

        let title = if success {
            String(localized: "title_brew_updated", table: "Notifications")
        } else if filteredUpgraded.isEmpty, externalSuccessNames.isEmpty, skippedNames.isEmpty {
            String(localized: "title_upgrade_failed", table: "Notifications")
        } else {
            String(localized: "title_partial_upgrade", table: "Notifications")
        }

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
        for name in failedNames {
            if let reason = failedErrors[name] {
                lines.append(String(localized: "line_package_failed_reason \(name) \(reason)", table: "Notifications"))
            } else {
                lines.append(String(localized: "line_package_failed \(name)", table: "Notifications"))
            }
        }

        return (title, lines.joined(separator: "\n"))
    }

    // MARK: - Auth

    /// Notify the user that authorization is required.
    func showAuthRequired(packageNames: [String], isRetry: Bool = false) {
        guard settings?.notifyOnAuthRequired != false else { return }
        let result = authRequiredContent(packageNames: packageNames, isRetry: isRetry)
        let content = buildContent(title: result.title, body: result.body)
        content.categoryIdentifier = Category.authRequired
        // Retries reuse a fixed ID so each wrong-password banner replaces the previous one
        let identifier = isRetry ? RequestID.authRetry : RequestID.authTrigger
        schedule(content: content, identifier: identifier)
    }

    func authRequiredContent(packageNames: [String], isRetry: Bool) -> (title: String, body: String) {
        let names = packageNames.joined(separator: ", ")
        if isRetry {
            return (
                String(localized: "title_auth_failed", table: "Notifications"),
                String(localized: "body_auth_failed_retry \(names)", table: "Notifications")
            )
        } else {
            return (
                String(localized: "title_auth_required", table: "Notifications"),
                String(localized: "body_auth_required \(names)", table: "Notifications")
            )
        }
    }

    /// Notify the user that authorization timed out.
    func showAuthTimeout(packageName: String) {
        guard settings?.notifyOnAuthRequired != false else { return }
        let result = authTimeoutContent(packageName: packageName)
        schedule(title: result.title, body: result.body, identifier: RequestID.error())
    }

    func authTimeoutContent(packageName: String) -> (title: String, body: String) {
        (
            String(localized: "title_auth_timeout", table: "Notifications"),
            String(localized: "body_auth_timeout \(packageName)", table: "Notifications")
        )
    }

    // MARK: - Transient Error

    /// Post a transient (non-fatal) error notification.
    func showTransientError(error: BrewError, packageName: String? = nil) {
        guard settings?.notifyOnErrors != false else { return }
        let result = transientErrorContent(error: error, packageName: packageName)
        schedule(title: result.title, body: result.body, identifier: RequestID.error())
    }

    func transientErrorContent(error: BrewError, packageName: String?) -> (title: String, body: String) {
        switch error {
        case .authenticationFailed:
            if let name = packageName {
                (
                    String(localized: "title_auth_failed", table: "Notifications"),
                    String(localized: "body_transient_auth_failed \(name)", table: "Notifications")
                )
            } else {
                (
                    String(localized: "title_auth_failed", table: "Notifications"),
                    String(localized: "body_transient_warning \(error.userMessage)", table: "Notifications")
                )
            }
        case .networkUnavailable:
            (
                String(localized: "title_network_unavailable", table: "Notifications"),
                String(localized: "body_transient_warning \(error.userMessage)", table: "Notifications")
            )
        default:
            (
                String(localized: "title_command_failed", table: "Notifications"),
                String(localized: "body_transient_error \(error.userMessage)", table: "Notifications")
            )
        }
    }

    // MARK: - Brew Not Found

    /// Notify the user that Homebrew could not be found (fatal error).
    func showBrewNotFound() {
        let result = brewNotFoundContent()
        schedule(title: result.title, body: result.body, identifier: RequestID.brewNotFound)
    }

    func brewNotFoundContent() -> (title: String, body: String) {
        (
            String(localized: "title_brew_not_found", table: "Notifications"),
            String(localized: "body_brew_not_found", table: "Notifications")
        )
    }

    // MARK: - Private Scheduling Helpers

    private func schedule(title: String, body: String, identifier: String) {
        let content = buildContent(title: title, body: body)
        schedule(content: content, identifier: identifier)
    }

    private func buildContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    private func schedule(content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        onRequestScheduled?(request)
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Action.authorize {
            Task { @MainActor in
                self.onAuthorizeActionTapped?()
            }
        }
        completionHandler()
    }
}
