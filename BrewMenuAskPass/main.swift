import Foundation
import AppKit

/// Present a password input dialog and return the entered password, or nil if cancelled.
func askPass(packageInfo: String?) -> String? {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Administrative Authorization", tableName: "Notifications", bundle: .main, comment: "")

    if let info = packageInfo {
        let format = NSLocalizedString("BrewMenu needs your password to update: %@", tableName: "Notifications", bundle: .main, comment: "")
        alert.informativeText = String(format: format, info)
    } else {
        alert.informativeText = NSLocalizedString("BrewMenu needs your password to complete the Homebrew upgrade.", tableName: "Notifications", bundle: .main, comment: "")
    }

    if let lockImage = NSImage(named: "NSLockLockedTemplate") {
        lockImage.isTemplate = false
        alert.icon = lockImage
    }

    alert.addButton(withTitle: NSLocalizedString("OK", tableName: "Notifications", bundle: .main, comment: ""))
    alert.addButton(withTitle: NSLocalizedString("Cancel", tableName: "Notifications", bundle: .main, comment: ""))

    let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    input.placeholderString = NSLocalizedString("Password", tableName: "Notifications", bundle: .main, comment: "")
    alert.accessoryView = input

    // Force frontmost and activate
    alert.window.level = .floating
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)

    let result = alert.runModal()
    if result == .alertFirstButtonReturn {
        return input.stringValue
    }
    return nil
}

// MARK: - Main Execution

let pid = ProcessInfo.processInfo.processIdentifier
let center = DistributedNotificationCenter.default()

// 1. Send started signal (notify the main app of a new authorization request)
center.postNotificationName(
    BrewMenuNotification.helperStarted,
    object: "\(pid)",
    userInfo: nil,
    deliverImmediately: true
)

// 2. Register for cross-process distributed notification
var triggered = false
var receivedPackageInfo: String?

let observer = center.addObserver(forName: BrewMenuNotification.triggerName(for: Int32(pid)), object: nil, queue: .main) { note in
    receivedPackageInfo = note.userInfo?["package_info"] as? String
    triggered = true
    CFRunLoopStop(CFRunLoopGetCurrent())
}

// 3. Listen for cancel signal from main app
let cancelObserver = center.addObserver(forName: BrewMenuNotification.cancelName(for: Int32(pid)), object: nil, queue: .main) { _ in
    exit(1)
}

// 4. Enter silent wait indefinitely (timeout is managed by the main app)
let env = ProcessInfo.processInfo.environment
CFRunLoopRun()

// 5. Clean up observers
center.removeObserver(observer)
center.removeObserver(cancelObserver)

// 5. If triggered by user click, show password dialog; otherwise exit on timeout
let packageInfo = receivedPackageInfo ?? env["BREW_MENU_PACKAGE_INFO"]
let result = triggered ? askPass(packageInfo: packageInfo) : nil

// 6. Send finished signal (notify the main app to clean up UI state)
center.postNotificationName(
    BrewMenuNotification.helperFinished,
    object: "\(pid)",
    userInfo: nil,
    deliverImmediately: true
)

if let pass = result {
    print(pass)
    exit(0)
} else {
    exit(1)
}
