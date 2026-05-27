import XCTest
@testable import AgentUsageBar

final class CodexProviderTests: XCTestCase {
    func testMapsRateLimitsSnapshotToNormalizedCodexSnapshot() throws {
        let snapshot = try CodexAppServerQuotaAdapter.mapSnapshot(
            rateLimitsResult: [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 47,
                        "windowDurationMins": 300,
                        "resetsAt": 1_779_835_567
                    ],
                    "secondary": [
                        "usedPercent": 9,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_780_179_695
                    ],
                    "credits": [
                        "hasCredits": true,
                        "unlimited": false,
                        "balance": "2459.8978250000"
                    ],
                    "planType": "plus"
                ]
            ],
            accountResult: [
                "account": [
                    "type": "chatgpt",
                    "email": "user@example.com",
                    "planType": "plus"
                ],
                "requiresOpenaiAuth": true
            ],
            now: Date(timeIntervalSince1970: 1_779_830_000)
        )

        XCTAssertEqual(snapshot.displayName, "Codex")
        XCTAssertEqual(snapshot.primaryBucket?.label, "5h")
        XCTAssertEqual(snapshot.primaryBucket?.percentUsed, 47)
        XCTAssertEqual(snapshot.primaryBucket?.remainingFraction, 0.53)
        XCTAssertEqual(snapshot.primaryBucket?.resetsAt, Date(timeIntervalSince1970: 1_779_835_567))
        XCTAssertEqual(snapshot.secondaryBucket?.label, "Weekly")
        XCTAssertEqual(snapshot.secondaryBucket?.percentUsed, 9)
        XCTAssertEqual(snapshot.secondaryBucket?.remainingFraction, 0.91)
        XCTAssertEqual(snapshot.secondaryBucket?.resetsAt, Date(timeIntervalSince1970: 1_780_179_695))
        XCTAssertEqual(snapshot.credits?.balance, NSDecimalNumber(string: "2459.8978250000").decimalValue)
        XCTAssertEqual(snapshot.credits?.unlimited, false)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.account, "user@example.com")
    }

    func testPrefersCodexBucketFromRateLimitsByLimitId() throws {
        let snapshot = try CodexAppServerQuotaAdapter.mapSnapshot(
            rateLimitsResult: [
                "rateLimits": [
                    "primary": ["usedPercent": 100, "windowDurationMins": 300]
                ],
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["usedPercent": 25, "windowDurationMins": 300],
                        "secondary": ["usedPercent": 40, "windowDurationMins": 10080]
                    ]
                ]
            ],
            accountResult: [:],
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.primaryBucket?.percentUsed, 25)
        XCTAssertEqual(snapshot.secondaryBucket?.percentUsed, 40)
    }
}
