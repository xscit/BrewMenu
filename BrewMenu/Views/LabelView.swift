import SwiftUI

/// Menu bar icon: dynamically switches based on current app status.
struct LabelView: View {
    let status: AppStatus

    var body: some View {
        switch status {
        case .idle:
            Image(systemName: "shippingbox")
                .accessibilityLabel(Text("acc_uptodate", tableName: "Menu"))
        case .scanning:
            Image(systemName: "arrow.clockwise")
                .accessibilityLabel(Text("acc_scanning", tableName: "Menu"))
        case .outdated:
            Image(systemName: "shippingbox.fill")
                .accessibilityLabel(Text("acc_updates_available", tableName: "Menu"))
        case .updating:
            Image(systemName: "arrow.up.circle.fill")
                .accessibilityLabel(Text("acc_updating", tableName: "Menu"))
        case .authorizing:
            Image(systemName: "touchid")
                .accessibilityLabel(Text("acc_auth_required", tableName: "Menu"))
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel(Text("acc_error", tableName: "Menu"))
        }
    }
}
