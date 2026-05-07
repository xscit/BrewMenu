import SwiftUI

/// Settings view: tab-based layout, each tab auto-sizes to its content.
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    private var settings: AppSettings { coordinator.settings }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(String(localized: "sec_general", table: "Settings"), systemImage: "gearshape")
                }
            scheduleTab
                .tabItem {
                    Label(String(localized: "sec_schedule", table: "Settings"), systemImage: "clock")
                }
            upgradeTab
                .tabItem {
                    Label(String(localized: "sec_upgrade", table: "Settings"), systemImage: "arrow.up.circle")
                }
            authorizationTab
                .tabItem {
                    Label(String(localized: "sec_authorization", table: "Settings"), systemImage: "lock")
                }
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Toggle(isOn: Bindable(settings).isLaunchAtLoginEnabled) {
                Text("lbl_launch_at_login", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
        .fixedSize()
        .padding(.bottom)
    }

    private var scheduleTab: some View {
        Form {
            Picker(selection: Bindable(settings).checkInterval) {
                ForEach(CheckInterval.allCases) { interval in
                    Text(interval.description).tag(interval)
                }
            } label: {
                Text("lbl_check_interval", tableName: "Settings")
            }
            .pickerStyle(.menu)

            if settings.checkInterval == .custom {
                LabeledContent(String(localized: "lbl_interval_colon", table: "Settings")) {
                    HStack(spacing: 6) {
                        TextField("", value: .init(
                            get: { settings.customCheckInterval / 60 },
                            set: { settings.customCheckInterval = max(1, $0) * 60 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        Text("lbl_minutes", tableName: "Settings")
                            .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize()
        .padding(.bottom)
    }

    private var upgradeTab: some View {
        Form {
            Toggle(isOn: Bindable(settings).isAutoUpgradeEnabled) {
                Text("lbl_auto_upgrade", tableName: "Settings")
            }

            Picker(selection: Bindable(settings).greedyMode) {
                ForEach(GreedyMode.allCases) { mode in
                    Text(mode.description).tag(mode)
                }
            } label: {
                Text("lbl_greedy_mode", tableName: "Settings")
            }
            .pickerStyle(.menu)

            Picker(selection: Bindable(settings).cleanupMode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.description).tag(mode)
                }
            } label: {
                Text("lbl_auto_cleanup", tableName: "Settings")
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        .fixedSize()
        .padding(.bottom)
    }

    private var authorizationTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent(String(localized: "lbl_auth_timeout_colon", table: "Settings")) {
                    HStack(spacing: 6) {
                        TextField("", value: .init(
                            get: { settings.authTimeout / 60 },
                            set: { settings.authTimeout = max(1, $0) * 60 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        Text("lbl_minutes", tableName: "Settings")
                            .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
            }
            .formStyle(.grouped)

        }
        .fixedSize()
        .padding(.bottom)
    }
}
