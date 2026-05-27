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

    func testNoAlertsWhenAllOff() {
        let alerts = crossedThresholds(
            threshold5h: 0, threshold7d: 0, thresholdExtra: 0,
            previous5h: 40, previous7d: 30, previousExtra: 20,
            current5h: 90, current7d: 85, currentExtra: 80
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testOnly5hFires() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 0, thresholdExtra: 0,
            previous5h: 70, previous7d: 50, previousExtra: 10,
            current5h: 85, current7d: 90, currentExtra: 50
        )
        XCTAssertEqual(alerts, [ThresholdAlert(window: "5-hour", pct: 85)])
    }

    func testOnly7dFires() {
        let alerts = crossedThresholds(
            threshold5h: 0, threshold7d: 80, thresholdExtra: 0,
            previous5h: 70, previous7d: 70, previousExtra: 10,
            current5h: 85, current7d: 85, currentExtra: 50
        )
        XCTAssertEqual(alerts, [ThresholdAlert(window: "7-day", pct: 85)])
    }

    func testOnlyExtraFires() {
        let alerts = crossedThresholds(
            threshold5h: 0, threshold7d: 0, thresholdExtra: 50,
            previous5h: 70, previous7d: 70, previousExtra: 40,
            current5h: 85, current7d: 85, currentExtra: 60
        )
        XCTAssertEqual(alerts, [ThresholdAlert(window: "Extra usage", pct: 60)])
    }

    func testAllThreeFireSimultaneously() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 80, thresholdExtra: 50,
            previous5h: 70, previous7d: 70, previousExtra: 40,
            current5h: 85, current7d: 90, currentExtra: 60
        )
        XCTAssertEqual(alerts, [
            ThresholdAlert(window: "5-hour", pct: 85),
            ThresholdAlert(window: "7-day", pct: 90),
            ThresholdAlert(window: "Extra usage", pct: 60),
        ])
    }

    func testNoAlertWhenStayingAbove() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 80, thresholdExtra: 50,
            previous5h: 85, previous7d: 90, previousExtra: 60,
            current5h: 88, current7d: 92, currentExtra: 65
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testNoAlertWhenStayingBelow() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 80, thresholdExtra: 50,
            previous5h: 50, previous7d: 60, previousExtra: 30,
            current5h: 70, current7d: 75, currentExtra: 45
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testExactThresholdTriggers() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 0, thresholdExtra: 0,
            previous5h: 79, previous7d: 50, previousExtra: 10,
            current5h: 80, current7d: 50, currentExtra: 10
        )
        XCTAssertEqual(alerts, [ThresholdAlert(window: "5-hour", pct: 80)])
    }

    func testFirstPollFiresWhenAlreadyAboveThreshold() {
        let alerts = crossedThresholds(
            threshold5h: 25, threshold7d: 5, thresholdExtra: 0,
            previous5h: 0, previous7d: 0, previousExtra: 0,
            current5h: 60, current7d: 40, currentExtra: 10
        )
        XCTAssertEqual(alerts, [
            ThresholdAlert(window: "5-hour", pct: 60),
            ThresholdAlert(window: "7-day", pct: 40),
        ])
    }

    func testFirstPollDoesNotFireWhenBelowThreshold() {
        let alerts = crossedThresholds(
            threshold5h: 80, threshold7d: 80, thresholdExtra: 0,
            previous5h: 0, previous7d: 0, previousExtra: 0,
            current5h: 30, current7d: 50, currentExtra: 10
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testDifferentThresholdsPerWindow() {
        let alerts = crossedThresholds(
            threshold5h: 90, threshold7d: 50, thresholdExtra: 70,
            previous5h: 85, previous7d: 45, previousExtra: 65,
            current5h: 95, current7d: 55, currentExtra: 75
        )
        XCTAssertEqual(alerts, [
            ThresholdAlert(window: "5-hour", pct: 95),
            ThresholdAlert(window: "7-day", pct: 55),
            ThresholdAlert(window: "Extra usage", pct: 75),
        ])
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "AgentUsageBarTests.NotificationService.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
