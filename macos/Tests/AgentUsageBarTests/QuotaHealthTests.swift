import XCTest
@testable import AgentUsageBar

final class QuotaHealthTests: XCTestCase {
    func testQuotaHealthBoundaries() {
        XCTAssertEqual(QuotaHealth.from(percentLeft: 100), .healthy)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 51), .healthy)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 50), .caution)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 21), .caution)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 20), .caution)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 11), .warning)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 10), .warning)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 9), .critical)
        XCTAssertEqual(QuotaHealth.from(percentLeft: 0), .critical)
    }

    func testBucketHealthColorBandsUsePercentLeft() {
        let criticalBucket = NormalizedUsageBucket(label: "5h", percentUsed: 92, resetsAt: nil)
        let cautionBucket = NormalizedUsageBucket(label: "Weekly", percentUsed: 75, resetsAt: nil)

        XCTAssertEqual(criticalBucket.percentLeft, 8)
        XCTAssertEqual(criticalBucket.quotaHealth, .critical)
        XCTAssertEqual(cautionBucket.percentLeft, 25)
        XCTAssertEqual(cautionBucket.quotaHealth, .caution)
    }

    func testBarHealthIsIndependentOfDisplayMode() {
        let bucket = NormalizedUsageBucket(label: "5h", percentUsed: 92, resetsAt: nil)

        XCTAssertEqual(displayPercent(bucket.percentUsed, mode: .used).value, 92)
        XCTAssertEqual(displayPercent(bucket.percentUsed, mode: .left).value, 8)
        XCTAssertEqual(bucket.quotaHealth, .critical)
    }
}
