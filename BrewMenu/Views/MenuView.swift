import SwiftUI

/// Main menu view: assembles functional sections into the complete dropdown menu.
struct MenuView<C: BrewMenuCoordinating>: View {
    let coordinator: C
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 1. Status display
        StatusHeaderView(coordinator: coordinator)

        // 2. Cancel button during scan or upgrade
        if coordinator.status == .scanning || coordinator.status == .updating || coordinator.status == .authorizing {
            Divider()
            Button(role: .destructive, action: { coordinator.cancel() }, label: {
                Label {
                    Text("btn_cancel_upgrade", tableName: "Menu")
                } icon: {
                    Image(systemName: "xmark.circle")
                }
            })
            .keyboardShortcut(".", modifiers: [.command])
        }

        // 3. Core actions (refresh, upgrade)
        if showCoreActions {
            Divider()

            if coordinator.status == .outdated {
                UpgradeActionSection(coordinator: coordinator)
                Divider()
            }

            Button(action: { Task { await coordinator.check() } }, label: {
                Label {
                    Text("btn_check_for_updates", tableName: "Menu")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            })
            .accessibilityIdentifier("btn_check_updates")
            .keyboardShortcut("r")
        }

        Divider()

        // 4. App management
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Label {
                Text("menu_settings", tableName: "Menu")
            } icon: {
                Image(systemName: "gearshape")
            }
        }
        .keyboardShortcut(",")

        Button(action: { NSApp.terminate(nil) }, label: {
            Label {
                Text("menu_quit", tableName: "Menu")
            } icon: {
                Image(systemName: "power")
            }
        })
        .keyboardShortcut("q")
    }

    private var showCoreActions: Bool {
        coordinator.status == .idle || coordinator.status == .outdated
    }
}
