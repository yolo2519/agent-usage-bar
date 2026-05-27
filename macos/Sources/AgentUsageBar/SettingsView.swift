import SwiftUI
import ServiceManagement

struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var codexProvider: CodexProvider
    @ObservedObject var notificationService: NotificationService

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()

                Picker("Polling Interval", selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { mins in
                        Text(pollingOptionLabel(for: mins))
                            .tag(mins)
                    }
                }
            }

            Section("Notifications") {
                ForEach(notificationProviderDescriptors) { descriptor in
                    ProviderNotificationSection(
                        descriptor: descriptor,
                        settings: notificationService.settings(for: descriptor.providerId),
                        notificationService: notificationService
                    )
                }

                if notificationService.notificationPermissionDenied {
                    Label("Notifications are disabled in System Settings.", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Account") {
                ProviderAccountSection(
                    providerName: "Claude",
                    account: service.accountEmail,
                    plan: nil,
                    unavailableText: service.isAuthenticated ? nil : "Not signed in",
                    signOutAction: service.isAuthenticated ? { service.signOut() } : nil
                )

                Divider()

                ProviderAccountSection(
                    providerName: "Codex",
                    account: codexProvider.snapshot?.account,
                    plan: codexProvider.snapshot?.plan,
                    unavailableText: codexProvider.lastError == nil ? "Managed by Codex CLI" : "Unavailable",
                    signOutAction: nil
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusSettingsWindow()
        }
    }

    private var notificationProviderDescriptors: [ProviderNotificationDescriptor] {
        [
            ProviderNotificationDescriptor(
                providerId: UsageProviderID.claude,
                displayName: service.currentSnapshot.displayName,
                primaryLabel: service.currentSnapshot.primaryBucket?.label ?? "5-hour window",
                secondaryLabel: service.currentSnapshot.secondaryBucket?.label ?? "7-day window",
                extraLabel: "Extra usage"
            ),
            ProviderNotificationDescriptor(
                providerId: UsageProviderID.codex,
                displayName: codexProvider.snapshot?.displayName ?? codexProvider.displayName,
                primaryLabel: codexProvider.snapshot?.primaryBucket?.label ?? "5-hour window",
                secondaryLabel: codexProvider.snapshot?.secondaryBucket?.label ?? "Weekly window",
                extraLabel: "Credits low"
            )
        ]
    }
}

private struct ProviderNotificationDescriptor: Identifiable {
    let providerId: String
    let displayName: String
    let primaryLabel: String
    let secondaryLabel: String
    let extraLabel: String

    var id: String { providerId }
}

private struct ProviderNotificationSection: View {
    let descriptor: ProviderNotificationDescriptor
    let settings: ProviderNotificationSettings
    @ObservedObject var notificationService: NotificationService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(descriptor.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)

            NotificationThresholdPicker(
                label: descriptor.primaryLabel,
                value: settings.fiveHourThresholdPct,
                onChange: { notificationService.setFiveHourThreshold($0, for: descriptor.providerId) }
            )

            NotificationThresholdPicker(
                label: descriptor.secondaryLabel,
                value: settings.weeklyThresholdPct,
                onChange: { notificationService.setWeeklyThreshold($0, for: descriptor.providerId) }
            )

            Toggle(descriptor.extraLabel, isOn: Binding(
                get: { settings.extraUsageEnabled },
                set: { notificationService.setExtraUsageEnabled($0, for: descriptor.providerId) }
            ))
        }
        .padding(.vertical, 4)
    }
}

private struct NotificationThresholdPicker: View {
    let label: String
    let value: Int?
    let onChange: (Int?) -> Void

    var body: some View {
        LabeledContent(label) {
            Picker(label, selection: Binding(
                get: { value },
                set: { onChange($0) }
            )) {
                Text("Off").tag(nil as Int?)
                Text("50%").tag(Optional(50))
                Text("25%").tag(Optional(25))
                Text("10%").tag(Optional(10))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
    }
}

private struct ProviderAccountSection: View {
    let providerName: String
    let account: String?
    let plan: String?
    let unavailableText: String?
    let signOutAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(providerName)
                .font(.subheadline)
                .fontWeight(.semibold)

            if let account {
                Text(account)
            } else if let unavailableText {
                Text(unavailableText)
                    .foregroundStyle(.secondary)
            }

            if let plan {
                Text(plan.capitalized)
                    .foregroundStyle(.secondary)
            }

            if let signOutAction {
                Button("Sign Out") {
                    signOutAction()
                }
            }
        }
    }
}

@MainActor
private func focusSettingsWindow() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.last(where: { $0.isVisible && $0.canBecomeKey }) {
            window.title = "Agent Usage Bar"
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @StateObject private var model: LaunchAtLoginModel
    private let controlSize: ControlSize
    private let useSwitchStyle: Bool

    init(
        controlSize: ControlSize = .regular,
        useSwitchStyle: Bool = false,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        _model = StateObject(
            wrappedValue: LaunchAtLoginModel(bundleURL: bundleURL)
        )
        self.controlSize = controlSize
        self.useSwitchStyle = useSwitchStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggle

            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var toggle: some View {
        let baseToggle = Toggle("Launch at Login", isOn: Binding(
            get: { model.isEnabled },
            set: { model.setEnabled($0) }
        ))
        .disabled(!model.isSupported)
        .controlSize(controlSize)

        if useSwitchStyle {
            baseToggle.toggleStyle(.switch)
        } else {
            baseToggle
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isSupported: Bool
    @Published private(set) var message: String?

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isSupported = supportsLaunchAtLoginManagement(appURL: bundleURL)

        guard isSupported else {
            message = "Install the app in Applications to manage launch at login."
            return
        }

        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            message = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            message = "Could not update launch at login."
        }
    }
}

func supportsLaunchAtLoginManagement(
    appURL: URL = Bundle.main.bundleURL,
    installDirectories: [URL] = launchAtLoginInstallDirectories()
) -> Bool {
    let normalizedAppURL = appURL.resolvingSymlinksInPath().standardizedFileURL

    return installDirectories.contains { directory in
        let normalizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = normalizedDirectory.path
        let appPath = normalizedAppURL.path

        return appPath == directoryPath || appPath.hasPrefix(directoryPath + "/")
    }
}

func launchAtLoginInstallDirectories(fileManager: FileManager = .default) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    ]
}
