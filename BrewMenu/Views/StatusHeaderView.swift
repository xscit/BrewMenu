import SwiftUI

// Static stored properties are not supported in generic types; declare at file scope.
private let statusTimeFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .short
    dateFormatter.timeStyle = .medium
    return dateFormatter
}()

/// Status header: displays the current app status (idle, scanning, updating, etc.) in the menu.
struct StatusHeaderView<C: BrewMenuCoordinating>: View {
    let coordinator: C

    var body: some View {
        switch coordinator.status {
        case .idle:
            statusWithTime(title: Text("status_uptodate", tableName: "Menu"), color: .secondary)
        case .scanning:
            statusLabel(Text("status_scanning", tableName: "Menu"))
        case .outdated:
            statusWithTime(title: Text("status_updates_available \(coordinator.outdatedPackages.count)", tableName: "Menu"), color: .primary)
                .font(.headline)
        case .updating:
            if let active = coordinator.activeUpgradePackageName {
                statusLabel(Text("status_updating_package \(active)", tableName: "Menu"))
            } else {
                statusLabel(Text("status_updating", tableName: "Menu"))
            }
        case .authorizing:
            Button(action: { coordinator.triggerAuthorizationUI() }, label: {
                Label {
                    Text("status_authorize", tableName: "Menu")
                } icon: {
                    Image(systemName: "lock.fill")
                }
            })
            .keyboardShortcut("a")
        case .error(let error):
            statusLabel(Text(LocalizedStringKey(error.userMessage), tableName: "Errors"), color: .red)
        }
    }

    @ViewBuilder
    private func statusLabel(_ title: Text, color: Color = .primary) -> some View {
        Label {
            title
                .foregroundStyle(color)
        } icon: {
            emptyIcon
        }
    }

    @ViewBuilder
    private func statusWithTime(title: Text, color: Color) -> some View {
        statusLabel(title, color: color)
        statusLabel(Text("status_last_checked \(lastCheckText)", tableName: "Menu"), color: .secondary)
    }

    private var lastCheckText: String {
        guard let date = coordinator.lastCheckDate else {
            return String(localized: "status_never", table: "Menu")
        }
        return statusTimeFormatter.string(from: date)
    }

    /// Placeholder icon to keep label layout consistent when no icon is needed.
    private var emptyIcon: some View {
        Image(nsImage: NSImage())
            .accessibilityHidden(true)
    }
}
