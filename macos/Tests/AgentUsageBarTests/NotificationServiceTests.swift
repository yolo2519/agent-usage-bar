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

    func testNoAlertsWhenThresholdsAreOff() {
        var fired = Set<String>()

        let alerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 8, secondaryLeft: 12),
            settings: .off,
            firedBucketKeys: &fired
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testFiresWhenPercentLeftIsAtOrBelowThreshold() {
        var fired = Set<String>()
        let reset = Date(timeIntervalSince1970: 1_779_835_567)

        let alerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20, secondaryLeft: 91, primaryReset: reset),
            settings: ProviderNotificationSettings(
                fiveHourThresholdPct: 20,
                weeklyThresholdPct: 10,
                extraUsageEnabled: false
            ),
            firedBucketKeys: &fired
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
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired
        )
        let second = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 10),
            settings: settings,
            firedBucketKeys: &fired
        )

        XCTAssertTrue(second.isEmpty)
    }

    func testResetsFiredFlagWhenPercentLeftRisesAboveThreshold() {
        var fired = Set<String>()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired
        )
        _ = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 40),
            settings: settings,
            firedBucketKeys: &fired
        )
        let third = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 15),
            settings: settings,
            firedBucketKeys: &fired
        )

        XCTAssertEqual(third.map(\.bucketId), ["primary"])
    }

    func testTracksProviderBucketStateIndependently() {
        var fired = Set<String>()
        let settings = ProviderNotificationSettings(
            fiveHourThresholdPct: 25,
            weeklyThresholdPct: nil,
            extraUsageEnabled: false
        )

        _ = thresholdAlerts(
            providerId: UsageProviderID.claude,
            snapshot: snapshot(displayName: "Claude", primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired
        )
        let codexAlerts = thresholdAlerts(
            providerId: UsageProviderID.codex,
            snapshot: snapshot(primaryLeft: 20),
            settings: settings,
            firedBucketKeys: &fired
        )

        XCTAssertEqual(codexAlerts.map(\.providerId), [UsageProviderID.codex])
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
                    percentLeft: $0,
                    progressFraction: $0 / 100,
                    consumedFraction: 1 - ($0 / 100),
                    resetsAt: primaryReset,
                    displayMode: .left
                )
            },
            secondaryBucket: secondaryLeft.map {
                NormalizedUsageBucket(
                    label: "Weekly",
                    percentLeft: $0,
                    progressFraction: $0 / 100,
                    consumedFraction: 1 - ($0 / 100),
                    resetsAt: nil,
                    displayMode: .left
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
