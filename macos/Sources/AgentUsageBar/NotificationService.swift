import Foundation
@preconcurrency import UserNotifications

struct ThresholdAlert: Equatable {
    let window: String
    let pct: Int
}

/// Pure logic: returns which threshold alerts should fire given a state transition.
func crossedThresholds(
    threshold5h: Int,
    threshold7d: Int,
    thresholdExtra: Int,
    previous5h: Double,
    previous7d: Double,
    previousExtra: Double,
    current5h: Double,
    current7d: Double,
    currentExtra: Double
) -> [ThresholdAlert] {
    var alerts = [ThresholdAlert]()

    if threshold5h > 0 {
        let t = Double(threshold5h)
        if current5h >= t && previous5h < t {
            alerts.append(ThresholdAlert(window: "5-hour", pct: Int(round(current5h))))
        }
    }

    if threshold7d > 0 {
        let t = Double(threshold7d)
        if current7d >= t && previous7d < t {
            alerts.append(ThresholdAlert(window: "7-day", pct: Int(round(current7d))))
        }
    }

    if thresholdExtra > 0 {
        let t = Double(thresholdExtra)
        if currentExtra >= t && previousExtra < t {
            alerts.append(ThresholdAlert(window: "Extra usage", pct: Int(round(currentExtra))))
        }
    }

    return alerts
}

private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
class NotificationService: ObservableObject {
    @Published private(set) var providerSettings: [String: ProviderNotificationSettings]

    private var previousPct5h: Double?
    private var previousPct7d: Double?
    private var previousPctExtra: Double?
    private var legacyThresholdExtra: Int
    private let userDefaults: UserDefaults
    private let systemNotificationsEnabled: Bool
    private let delegate = NotificationDelegate()

    /// Compatibility accessors for the pre-provider settings UI. These remain
    /// expressed as percent used until the UI moves to provider settings.
    var threshold5h: Int {
        guard let percentLeft = settings(for: UsageProviderID.claude).fiveHourThresholdPct else { return 0 }
        return 100 - percentLeft
    }

    var threshold7d: Int {
        guard let percentLeft = settings(for: UsageProviderID.claude).weeklyThresholdPct else { return 0 }
        return 100 - percentLeft
    }

    var thresholdExtra: Int {
        settings(for: UsageProviderID.claude).extraUsageEnabled ? legacyThresholdExtra : 0
    }

    init(
        userDefaults: UserDefaults = .standard,
        systemNotificationsEnabled: Bool = Bundle.main.bundleURL.pathExtension == "app"
    ) {
        self.userDefaults = userDefaults
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.legacyThresholdExtra = Self.load("notificationThresholdExtra", from: userDefaults)
        self.providerSettings = Self.loadProviderSettings(from: userDefaults)
        if systemNotificationsEnabled {
            UNUserNotificationCenter.current().delegate = delegate
        }
    }

    func setThreshold5h(_ value: Int) {
        let clamped = clamp(value)
        setFiveHourThreshold(clamped > 0 ? 100 - clamped : nil, for: UsageProviderID.claude)
        userDefaults.set(clamped, forKey: "notificationThreshold5h")
        previousPct5h = nil
    }

    func setThreshold7d(_ value: Int) {
        let clamped = clamp(value)
        setWeeklyThreshold(clamped > 0 ? 100 - clamped : nil, for: UsageProviderID.claude)
        userDefaults.set(clamped, forKey: "notificationThreshold7d")
        previousPct7d = nil
    }

    func setThresholdExtra(_ value: Int) {
        legacyThresholdExtra = clamp(value)
        setExtraUsageEnabled(legacyThresholdExtra > 0, for: UsageProviderID.claude)
        userDefaults.set(legacyThresholdExtra, forKey: "notificationThresholdExtra")
        previousPctExtra = nil
    }

    func settings(for providerId: String) -> ProviderNotificationSettings {
        providerSettings[providerId] ?? .off
    }

    func setFiveHourThreshold(_ value: Int?, for providerId: String) {
        updateSettings(for: providerId) { settings in
            settings.fiveHourThresholdPct = clampedOptional(value)
        }
        if value != nil { requestPermission() }
    }

    func setWeeklyThreshold(_ value: Int?, for providerId: String) {
        updateSettings(for: providerId) { settings in
            settings.weeklyThresholdPct = clampedOptional(value)
        }
        if value != nil { requestPermission() }
    }

    func setExtraUsageEnabled(_ enabled: Bool, for providerId: String) {
        updateSettings(for: providerId) { settings in
            settings.extraUsageEnabled = enabled
        }
        if enabled { requestPermission() }
    }

    func requestPermission() {
        guard systemNotificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAndNotify(pct5h: Double, pct7d: Double, pctExtra: Double) {
        let current5h = pct5h * 100
        let current7d = pct7d * 100
        let currentExtra = pctExtra * 100

        let prev5h = previousPct5h ?? 0
        let prev7d = previousPct7d ?? 0
        let prevExtra = previousPctExtra ?? 0

        defer {
            previousPct5h = current5h
            previousPct7d = current7d
            previousPctExtra = currentExtra
        }

        let alerts = crossedThresholds(
            threshold5h: threshold5h,
            threshold7d: threshold7d,
            thresholdExtra: thresholdExtra,
            previous5h: prev5h,
            previous7d: prev7d,
            previousExtra: prevExtra,
            current5h: current5h,
            current7d: current7d,
            currentExtra: currentExtra
        )

        for alert in alerts {
            sendNotification(window: alert.window, pct: alert.pct)
        }
    }

    private func sendNotification(window: String, pct: Int) {
        guard systemNotificationsEnabled else {
            print("[Notification] \(window) usage has reached \(pct)% (no bundle – skipped)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude Usage"
        content.body = "\(window) usage has reached \(pct)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(window)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notification] Failed to deliver: \(error)")
            } else {
                print("[Notification] Delivered: \(window) at \(pct)%")
            }
        }
    }

    private func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private func clampedOptional(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return clamp(value)
    }

    private func updateSettings(for providerId: String, mutate: (inout ProviderNotificationSettings) -> Void) {
        var settings = providerSettings[providerId] ?? .off
        mutate(&settings)
        providerSettings[providerId] = settings
        persistProviderSettings()
    }

    private func persistProviderSettings() {
        guard let data = try? JSONEncoder().encode(providerSettings) else { return }
        userDefaults.set(data, forKey: Self.providerSettingsKey)
    }

    private static func load(_ key: String, from userDefaults: UserDefaults) -> Int {
        let value = userDefaults.integer(forKey: key)
        return max(0, min(100, value))
    }

    private static func loadProviderSettings(from userDefaults: UserDefaults) -> [String: ProviderNotificationSettings] {
        if let data = userDefaults.data(forKey: providerSettingsKey),
           let settings = try? JSONDecoder().decode([String: ProviderNotificationSettings].self, from: data) {
            return settings
        }

        let migrated = migrateLegacySettings(from: userDefaults)
        if let data = try? JSONEncoder().encode(migrated) {
            userDefaults.set(data, forKey: providerSettingsKey)
        }
        return migrated
    }

    private static func migrateLegacySettings(from userDefaults: UserDefaults) -> [String: ProviderNotificationSettings] {
        let fiveHourUsed = load("notificationThreshold5h", from: userDefaults)
        let weeklyUsed = load("notificationThreshold7d", from: userDefaults)
        let extra = load("notificationThresholdExtra", from: userDefaults)

        return [
            UsageProviderID.claude: ProviderNotificationSettings(
                fiveHourThresholdPct: percentLeftThreshold(fromLegacyUsedThreshold: fiveHourUsed),
                weeklyThresholdPct: percentLeftThreshold(fromLegacyUsedThreshold: weeklyUsed),
                extraUsageEnabled: extra > 0
            ),
            UsageProviderID.codex: .off
        ]
    }

    private static func percentLeftThreshold(fromLegacyUsedThreshold value: Int) -> Int? {
        guard value > 0 else { return nil }
        return max(0, min(100, 100 - value))
    }

    private static let providerSettingsKey = "providerNotificationSettings.v1"
}
