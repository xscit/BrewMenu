import SwiftUI
import UserNotifications

/// Settings view: tab-based layout, each tab auto-sizes to its content.
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    private var settings: AppSettings {
        coordinator.settings
    }

    @State private var isCleaningUp = false
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

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
            notificationsTab
                .tabItem {
                    Label(String(localized: "sec_notifications", table: "Settings"), systemImage: "bell")
                }
            exclusionsTab
                .tabItem {
                    Label(String(localized: "sec_exclusions", table: "Settings"), systemImage: "pin.slash")
                }
            aboutTab
                .tabItem {
                    Label(String(localized: "sec_about", table: "Settings"), systemImage: "info.circle")
                }
        }
        .frame(width: 480)
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Toggle(isOn: Bindable(settings).isLaunchAtLoginEnabled) {
                Text("lbl_launch_at_login", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
    }

    private var scheduleTab: some View {
        Form {
            Section {
                Toggle(isOn: Bindable(settings).scanOnLaunch) {
                    Text("lbl_scan_on_launch", tableName: "Settings")
                }
            }

            Section {
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
                        ClampedIntField(
                            value: Binding(
                                get: { settings.customCheckInterval / 60 },
                                set: { settings.customCheckInterval = $0 * 60 }
                            ),
                            range: (DefaultsKey.minimumCustomIntervalSeconds / 60) ... (DefaultsKey.maximumCustomIntervalSeconds / 60),
                            unitKey: "lbl_minutes"
                        )
                    }
                }
            } footer: {
                Text("footer_check_interval", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
    }

    private var upgradeTab: some View {
        Form {
            Section {
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
            }

            Section {
                Picker(selection: Bindable(settings).cleanupSchedule) {
                    ForEach(CleanupSchedule.allCases) { schedule in
                        Text(schedule.description).tag(schedule)
                    }
                } label: {
                    Text("lbl_schedule", tableName: "Settings")
                }
                .pickerStyle(.menu)

                if settings.cleanupSchedule == .everyNDays {
                    LabeledContent(String(localized: "lbl_interval_colon", table: "Settings")) {
                        ClampedIntField(
                            value: Bindable(settings).cleanupIntervalDays,
                            range: DefaultsKey.minimumCleanupIntervalDays ... DefaultsKey.maximumCleanupIntervalDays,
                            unitKey: "lbl_days"
                        )
                    }
                }

                if settings.cleanupSchedule != .disabled {
                    LabeledContent(String(localized: "lbl_older_than_colon", table: "Settings")) {
                        ClampedIntField(
                            value: Bindable(settings).cleanupPruneDays,
                            range: 0 ... DefaultsKey.maximumCleanupPruneDays,
                            unitKey: "lbl_days"
                        )
                    }

                    Button {
                        isCleaningUp = true
                        Task {
                            await coordinator.cleanup()
                            isCleaningUp = false
                        }
                    } label: {
                        if isCleaningUp {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("btn_cleanup_now", tableName: "Settings")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("btn_cleanup_now", tableName: "Settings")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isCleaningUp)
                }
            } header: {
                Text("sec_cleanup", tableName: "Settings")
            } footer: {
                if settings.cleanupSchedule != .disabled {
                    Text("footer_prune_age", tableName: "Settings")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
    }

    private var notificationsTab: some View {
        Form {
            if notificationAuthStatus == .denied {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("footer_notifications_denied", tableName: "Settings")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "btn_open_system_settings", table: "Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Section {
                Toggle(isOn: Bindable(settings).notifyOnScanResults) {
                    NotificationToggleLabel(
                        titleKey: "lbl_notify_scan_results",
                        subtitleKey: "sub_notify_scan_results"
                    )
                }
                Toggle(isOn: Bindable(settings).notifyOnUpgradeResult) {
                    NotificationToggleLabel(
                        titleKey: "lbl_notify_upgrade_result",
                        subtitleKey: "sub_notify_upgrade_result"
                    )
                }
                Toggle(isOn: Bindable(settings).notifyOnAuthRequired) {
                    NotificationToggleLabel(
                        titleKey: "lbl_notify_auth_required",
                        subtitleKey: "sub_notify_auth_required"
                    )
                }
                Toggle(isOn: Bindable(settings).notifyOnErrors) {
                    NotificationToggleLabel(
                        titleKey: "lbl_notify_errors",
                        subtitleKey: "sub_notify_errors"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthStatus = settings.authorizationStatus
        }
    }

    private var exclusionsTab: some View {
        let pinned = settings.pinnedPackages.sorted()
        return Form {
            Section {
                if pinned.isEmpty {
                    Text("lbl_no_exclusions", tableName: "Settings")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    ForEach(pinned, id: \.self) { name in
                        LabeledContent(name) {
                            Button {
                                settings.pinnedPackages.remove(name)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "btn_remove_exclusion \(name)", table: "Settings"))
                        }
                    }
                    Button(role: .destructive) {
                        settings.pinnedPackages.removeAll()
                    } label: {
                        Text("btn_clear_all_exclusions", tableName: "Settings")
                            .frame(maxWidth: .infinity)
                    }
                }
            } footer: {
                Text("footer_exclusions", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
    }

    private var authorizationTab: some View {
        Form {
            LabeledContent(String(localized: "lbl_auth_timeout_colon", table: "Settings")) {
                ClampedIntField(
                    value: Binding(
                        get: { settings.authTimeout / 60 },
                        set: { settings.authTimeout = $0 * 60 }
                    ),
                    range: (DefaultsKey.minimumAuthTimeoutSeconds / 60) ... (DefaultsKey.maximumAuthTimeoutSeconds / 60),
                    unitKey: "lbl_minutes"
                )
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom)
    }

    private var aboutTab: some View {
        VStack(spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            VStack(spacing: 4) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "BrewMenu")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(String(
                    format: String(localized: "lbl_version_format", table: "Settings"),
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                ))
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }

            Link(String(localized: "lbl_github", table: "Settings"),
                 destination: URL(string: "https://github.com/xscit/BrewMenu")!)
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 40)
    }
}

private struct NotificationToggleLabel: View {
    let titleKey: String
    let subtitleKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(titleKey), tableName: "Settings")
            Text(LocalizedStringKey(subtitleKey), tableName: "Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ClampedIntField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unitKey: String

    @State private var text: String

    init(value: Binding<Int>, range: ClosedRange<Int>, unitKey: String) {
        _value = value
        self.range = range
        self.unitKey = unitKey
        _text = State(initialValue: "\(value.wrappedValue)")
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 56)
                .onChange(of: text) { _, new in
                    let digits = new.filter(\.isNumber)
                    if let num = Int(digits) {
                        let clamped = min(max(num, range.lowerBound), range.upperBound)
                        text = "\(clamped)"
                        value = clamped
                    } else {
                        text = digits
                    }
                }
                .onSubmit {
                    if text.isEmpty { text = "\(range.lowerBound)"; value = range.lowerBound }
                }
            Text(LocalizedStringKey(unitKey), tableName: "Settings")
                .foregroundStyle(.secondary)
            Text("(\(range.lowerBound)–\(range.upperBound))")
                .foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .onChange(of: value) { _, new in
            if Int(text) != new { text = "\(new)" }
        }
    }
}
