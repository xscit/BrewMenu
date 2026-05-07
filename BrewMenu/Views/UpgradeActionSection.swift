import SwiftUI

/// Upgrade actions: provides "Upgrade All" and individual upgrade entry points.
struct UpgradeActionSection<C: BrewMenuCoordinating>: View {
    let coordinator: C
    
    var body: some View {
        Group {
            Button(action: { Task { await coordinator.upgrade() } }) {
                Label {
                    Text("btn_upgrade_all", tableName: "Menu")
                } icon: {
                    Image(systemName: "arrow.up.circle.fill")
                }
            }
            .keyboardShortcut("u")
            
            Menu {
                ForEach(coordinator.outdatedPackages) { pkg in
                    Button(action: {
                        Task { await coordinator.upgrade(package: pkg) }
                    }) {
                        Text("pkg_upgrade_label \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", tableName: "Menu")
                    }
                    .accessibilityLabel(Text("pkg_upgrade_accessibility \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", tableName: "Menu"))
                }
            } label: {
                Label {
                    Text("btn_upgrade_individually", tableName: "Menu")
                } icon: {
                    Image(systemName: "list.bullet")
                }
            }
        }
    }
}
