import SwiftUI
import AppKit

@main
struct BrewMenuApp: App {
    init() {
        // Enforce single instance: if another copy with the same bundle ID is already
        // running (e.g., the installed app launched by a UNNotification action while
        // the debug build is active), quit immediately so there is only one menu bar icon.
        // Skip during unit tests: calling NSApp.terminate() before SwiftUI finishes
        // initialising its scene graph triggers an internal assertion in the test host.
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
        }
    }

    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuView(coordinator: coordinator)
        } label: {
            LabelView(status: coordinator.status)
                .accessibilityLabel("BrewMenu")
        }

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
