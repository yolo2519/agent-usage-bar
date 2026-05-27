import Foundation
import AppKit
@preconcurrency import UserNotifications

struct ProviderThresholdAlert: Equatable {
    enum Reason: Equatable {
        case customThreshold
        case healthBand
    }

    let providerId: String
    let providerName: String
    let bucketId: String
    let bucketLabel: String
    let percentLeft: Int
    let resetsAt: Date?
    let health: QuotaHealth?
    let reason: Reason

    init(
        providerId: String,
        providerName: String,
        bucketId: String,
        bucketLabel: String,
        percentLeft: Int,
        resetsAt: Date?,
        health: QuotaHealth? = nil,
        reason: Reason = .customThreshold
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.bucketId = bucketId
        self.bucketLabel = bucketLabel
        self.percentLeft = percentLeft
        self.resetsAt = resetsAt
        self.health = health
        self.reason = reason
    }
}

/// Pure logic: fire once when a bucket is at/below its percent-left threshold,
/// then reset the fired flag only after it rises above the threshold.
func thresholdAlerts(
    providerId: String,
    snapshot: NormalizedUsageSnapshot,
    settings: ProviderNotificationSettings,
    firedBucketKeys: inout Set<String>,
    firedHealthByBucket: inout [String: QuotaHealth]
) -> [ProviderThresholdAlert] {
    var numericAlerts = [ProviderThresholdAlert]()
    var healthAlerts = [ProviderThresholdAlert]()

    evaluateBucket(
        providerId: providerId,
        providerName: snapshot.displayName,
        bucketId: "primary",
        bucket: snapshot.primaryBucket,
        threshold: settings.fiveHourThresholdPct,
        firedBucketKeys: &firedBucketKeys,
        alerts: &numericAlerts
    )
    evaluateHealthBucket(
        providerId: providerId,
        providerName: snapshot.displayName,
        bucketId: "primary",
        bucket: snapshot.primaryBucket,
        firedHealthByBucket: &firedHealthByBucket,
        alerts: &healthAlerts
    )

    evaluateBucket(
        providerId: providerId,
        providerName: snapshot.displayName,
        bucketId: "secondary",
        bucket: snapshot.secondaryBucket,
        threshold: settings.weeklyThresholdPct,
        firedBucketKeys: &firedBucketKeys,
        alerts: &numericAlerts
    )
    evaluateHealthBucket(
        providerId: providerId,
        providerName: snapshot.displayName,
        bucketId: "secondary",
        bucket: snapshot.secondaryBucket,
        firedHealthByBucket: &firedHealthByBucket,
        alerts: &healthAlerts
    )

    return mergedAlerts(numericAlerts: numericAlerts, healthAlerts: healthAlerts)
}

private func evaluateBucket(
    providerId: String,
    providerName: String,
    bucketId: String,
    bucket: NormalizedUsageBucket?,
    threshold: Int?,
    firedBucketKeys: inout Set<String>,
    alerts: inout [ProviderThresholdAlert]
) {
    let key = "\(providerId):\(bucketId)"
    guard let threshold, let bucket else {
        firedBucketKeys.remove(key)
        return
    }

    let percentLeft = 100 - bucket.percentUsed
    if percentLeft <= threshold {
        guard !firedBucketKeys.contains(key) else { return }
        firedBucketKeys.insert(key)
        alerts.append(ProviderThresholdAlert(
            providerId: providerId,
            providerName: providerName,
            bucketId: bucketId,
            bucketLabel: bucket.label,
            percentLeft: percentLeft,
            resetsAt: bucket.resetsAt
        ))
    } else {
        firedBucketKeys.remove(key)
    }
}

private func evaluateHealthBucket(
    providerId: String,
    providerName: String,
    bucketId: String,
    bucket: NormalizedUsageBucket?,
    firedHealthByBucket: inout [String: QuotaHealth],
    alerts: inout [ProviderThresholdAlert]
) {
    let key = "\(providerId):\(bucketId)"
    guard let bucket else {
        firedHealthByBucket.removeValue(forKey: key)
        return
    }

    let health = bucket.quotaHealth
    guard health == .warning || health == .critical else {
        firedHealthByBucket.removeValue(forKey: key)
        return
    }

    let previouslyFired = firedHealthByBucket[key]
    firedHealthByBucket[key] = health

    if let previouslyFired, health.severity <= previouslyFired.severity {
        return
    }

    alerts.append(ProviderThresholdAlert(
        providerId: providerId,
        providerName: providerName,
        bucketId: bucketId,
        bucketLabel: bucket.label,
        percentLeft: bucket.percentLeft,
        resetsAt: bucket.resetsAt,
        health: health,
        reason: .healthBand
    ))
}

private func mergedAlerts(
    numericAlerts: [ProviderThresholdAlert],
    healthAlerts: [ProviderThresholdAlert]
) -> [ProviderThresholdAlert] {
    let healthKeys = Set(healthAlerts.map { "\($0.providerId):\($0.bucketId)" })
    return numericAlerts.filter { !healthKeys.contains("\($0.providerId):\($0.bucketId)") } + healthAlerts
}

private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}

@MainActor
class NotificationService: ObservableObject {
    @Published private(set) var providerSettings: [String: ProviderNotificationSettings]
    @Published private(set) var notificationPermissionDenied = false

    private var firedBucketKeys = Set<String>()
    private var firedHealthByBucket = [String: QuotaHealth]()
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
    }

    func setThreshold7d(_ value: Int) {
        let clamped = clamp(value)
        setWeeklyThreshold(clamped > 0 ? 100 - clamped : nil, for: UsageProviderID.claude)
        userDefaults.set(clamped, forKey: "notificationThreshold7d")
    }

    func setThresholdExtra(_ value: Int) {
        legacyThresholdExtra = clamp(value)
        setExtraUsageEnabled(legacyThresholdExtra > 0, for: UsageProviderID.claude)
        userDefaults.set(legacyThresholdExtra, forKey: "notificationThresholdExtra")
    }

    func settings(for providerId: String) -> ProviderNotificationSettings {
        providerSettings[providerId] ?? .off
    }

    func setFiveHourThreshold(_ value: Int?, for providerId: String) {
        updateSettings(for: providerId) { settings in
            settings.fiveHourThresholdPct = clampedOptional(value)
        }
        firedBucketKeys.remove("\(providerId):primary")
        if value != nil { requestPermission() }
    }

    func setWeeklyThreshold(_ value: Int?, for providerId: String) {
        updateSettings(for: providerId) { settings in
            settings.weeklyThresholdPct = clampedOptional(value)
        }
        firedBucketKeys.remove("\(providerId):secondary")
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.notificationPermissionDenied = !granted
            }
        }
    }

    func checkAndNotify(
        providerId: String,
        snapshot: NormalizedUsageSnapshot,
        settings: ProviderNotificationSettings
    ) {
        let alerts = thresholdAlerts(
            providerId: providerId,
            snapshot: snapshot,
            settings: settings,
            firedBucketKeys: &firedBucketKeys,
            firedHealthByBucket: &firedHealthByBucket
        )

        for alert in alerts {
            sendNotification(alert)
        }
    }

    private func sendNotification(_ alert: ProviderThresholdAlert) {
        let body = notificationBody(for: alert)

        guard systemNotificationsEnabled else {
            print("[Notification] \(body) (no bundle - skipped)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Agent Usage Bar"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(alert.providerId)-\(alert.bucketId)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notification] Failed to deliver: \(error)")
            } else {
                print("[Notification] Delivered: \(body)")
            }
        }
    }

    private func notificationBody(for alert: ProviderThresholdAlert) -> String {
        var body = "\(alert.providerName) \(alert.bucketLabel) limit"
        if alert.reason == .healthBand, let health = alert.health {
            body += " \(health)"
        }
        body += " at \(alert.percentLeft)%"
        if let resetsAt = alert.resetsAt {
            body += " - resets \(Self.resetTimeFormatter.string(from: resetsAt))"
        }
        return body
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

    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
