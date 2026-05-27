import SwiftUI

@main
struct AgentUsageBarApp: App {
    @StateObject private var service: UsageService
    @StateObject private var codexProvider: CodexProvider
    @StateObject private var historyService: UsageHistoryService
    @StateObject private var notificationService: NotificationService
    @StateObject private var appUpdater: AppUpdater

    init() {
        AppConfigMigration.migrateIfNeeded()
        _service = StateObject(wrappedValue: UsageService())
        _codexProvider = StateObject(wrappedValue: CodexProvider())
        _historyService = StateObject(wrappedValue: UsageHistoryService())
        _notificationService = StateObject(wrappedValue: NotificationService())
        _appUpdater = StateObject(wrappedValue: AppUpdater())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                codexProvider: codexProvider,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        } label: {
            Image(nsImage: service.isAuthenticated
                ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
                : renderUnauthenticatedIcon()
            )
                .help("Agent Usage Bar")
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                    codexProvider.startPolling()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
