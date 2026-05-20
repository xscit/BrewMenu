import SwiftUI

/// Upgrade actions: provides "Upgrade All" and individual upgrade entry points.
struct UpgradeActionSection<C: BrewMenuCoordinating>: View {
    let coordinator: C

    var body: some View {
        Group {
            Button(action: { Task { await coordinator.upgrade() } }, label: {
                Label {
                    Text("btn_upgrade_all", tableName: "Menu")
                } icon: {
                    Image(systemName: "arrow.up.circle.fill")
                }
            })
            .keyboardShortcut("u")

            Menu {
                ForEach(coordinator.outdatedPackages) { pkg in
                    Menu {
                        Button {
                            Task { await coordinator.upgrade(package: pkg) }
                        } label: {
                            Label {
                                Text("pkg_upgrade_label \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", tableName: "Menu")
                            } icon: {
                                Image(systemName: "arrow.up.circle")
                            }
                        }
                        .accessibilityLabel(Text("pkg_upgrade_accessibility \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", tableName: "Menu"))
                        Divider()
                        Button {
                            coordinator.pin(package: pkg)
                        } label: {
                            Label {
                                Text("btn_pin_package", tableName: "Menu")
                            } icon: {
                                Image(systemName: "pin.slash")
                            }
                        }
                    } label: {
                        Text("pkg_upgrade_label \(pkg.name) \(pkg.oldVersion) \(pkg.newVersion)", tableName: "Menu")
                    }
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
