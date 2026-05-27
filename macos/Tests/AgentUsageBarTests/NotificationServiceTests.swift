import XCTest
@testable import AgentUsageBar

final class NotificationServiceTests: XCTestCase {
    @MainActor
    func testMigratesLegacyClaudeThresholdsToProviderSettings() {
        let defaults = makeUserDefaults()
        defaults.set(80, forKey: "notificationThreshold5h")
        defaults.set(95, forKey: "notificationThreshold7d")
        defaults.set(50, forKey: "notificationThresholdExtra")

        let service = NotificationService(userDefaults: defaults)
        let settings = service.settings(for: UsageProviderID.claude)

        XCTAssertEqual(settings.fiveHourThresholdPct, 20)
        XCTAssertEqual(settings.weeklyThresholdPct, 5)
        XCTAssertTrue(settings.extraUsageEnabled)
        XCTAssertEqual(service.threshold5h, 80)
        XCTAssertEqual(service.threshold7d, 95)
        XCTAssertEqual(service.thresholdExtra, 50)
    }

    @MainActor
    func testMissingProviderSettingsDefaultToOff() {
        let service = NotificationService(userDefaults: makeUserDefaults())

        XCTAssertEqual(service.settings(for: "gemini"), .off)
    }

    func testBandAlertsFireWhenNumericThresholdsAreOff() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()

        let alerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 8, secondaryLeft: 12),
            settings: .off,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(alerts.map(\.reason), [.healthBand, .healthBand])
    }

    func testFiresWhenPercentLeftIsAtOrBelowThreshold() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let reset = Date(timeIntervalSince1970: 1_779_835_567)

        let alerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20, secondaryLeft: 91, primaryReset: reset),
            settings: ProviderNotificationSettings(
                fiveHourThresholdPct: 20,
                weeklyThresholdPct: 10,
                extraUsageEnabled: false
            ),
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(alerts, [
            ProviderThresholdAlert(
                providerId: UsageProviderID.codex,
                providerName: "Codex",
                bucketId: "primary",
                bucketLabel: "5h",
                percentLeft: 20,
                resetsAt: reset
            )
        ])
    }

    func testDoesNotSpamWhileBucketRemainsBelowThreshold() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        let second = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 10),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(second.map(\.reason), [.healthBand])
        XCTAssertEqual(second.first?.health, .warning)
    }

    func testResetsFiredFlagWhenPercentLeftRisesAboveThreshold() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 40),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        let third = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 15),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(third.map(\.bucketId), ["primary"])
    }

    func testTracksProviderBucketStateIndependently() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.claude,
            snapshot: snapshot(displayName: "Claude", primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        let codexAlerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(codexAlerts.map(\.providerId), [UsageProviderID.codex])
    }

    func testBandNotificationsFireOnWarningAndCriticalCrossingsOnly() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: nil,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        XCTAssertTrue(thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 25),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        ).isEmpty)

        let warning = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 15),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        XCTAssertEqual(warning.map(\.health), [.warning])

        XCTAssertTrue(thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 12),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        ).isEmpty)

        let critical = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 8),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        XCTAssertEqual(critical.map(\.health), [.critical])
    }

    func testBandNotificationResetsAfterHealthImproves() {
        var fired = Set<String>()
        var firedHealth = [String: QuotaHealth]()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: nil,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 8),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 55),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )
        let warningAgain = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 15),
            settings: settings,
            firedBucketKeys: &fired,
            firedHealthByBucket: &firedHealth
        )

        XCTAssertEqual(warningAgain.map(\.health), [.warning])
    }

    private func snapshot(
        displayName: String = "Codex",
        primaryLeft: Double? = nil,
        secondaryLeft: Double? = nil,
        primaryReset: Date? = nil
    ) -> NormalizedUsageSnapshot {
        NormalizedUsageSnapshot(
            displayName: displayName,
            primaryBucket: primaryLeft.map {
                NormalizedUsageBucket(
                    label: "5h",
                    percentUsed: Int(round(100 - $0)),
                    resetsAt: primaryReset
                )
            },
            secondaryBucket: secondaryLeft.map {
                NormalizedUsageBucket(
                    label: "Weekly",
                    percentUsed: Int(round(100 - $0)),
                    resetsAt: nil
                )
            },
            credits: nil,
            plan: nil,
            account: nil,
            model: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "AgentUsageBarTests.NotificationService.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
