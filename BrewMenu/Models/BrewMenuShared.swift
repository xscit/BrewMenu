import Foundation

/// Distributed notification name constants (shared between main App and AskPass Helper).
enum BrewMenuNotification {
    static let helperStarted = Notification.Name("com.whoami.brewmenu.helper.started")
    static let helperFinished = Notification.Name("com.whoami.brewmenu.helper.finished")

    /// Generate a PID-specific trigger notification name.
    static func triggerName(for pid: Int32) -> Notification.Name {
        Notification.Name("com.whoami.brewmenu.trigger.\(pid)")
    }

    /// Generate a PID-specific cancel notification name.
    static func cancelName(for pid: Int32) -> Notification.Name {
        Notification.Name("com.whoami.brewmenu.cancel.\(pid)")
    }
}
