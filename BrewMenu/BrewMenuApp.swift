import SwiftUI

@main
struct BrewMenuApp: App {
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
