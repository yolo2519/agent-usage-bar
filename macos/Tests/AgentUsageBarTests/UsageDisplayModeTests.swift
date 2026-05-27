import XCTest
@testable import AgentUsageBar

final class UsageDisplayModeTests: XCTestCase {
    func testDisplayPercentFlipsLabelWithoutChangingRemainingBarFill() {
        let bucket = NormalizedUsageBucket(
            label: "5h",
            percentUsed: 8,
            resetsAt: nil
        )

        let used = displayPercent(bucket.percentUsed, mode: .used)
        let left = displayPercent(bucket.percentUsed, mode: .left)

        XCTAssertEqual(used.value, 8)
        XCTAssertEqual(used.suffix, "%")
        XCTAssertEqual(left.value, 92)
        XCTAssertEqual(left.suffix, "% left")
        XCTAssertEqual(bucket.remainingFraction, 0.92)
    }

    func testDisplayPercentClampsThroughBucketCanonicalUsedValue() {
        let bucket = NormalizedUsageBucket(
            label: "Weekly",
            percentUsed: 130,
            resetsAt: nil
        )

        XCTAssertEqual(bucket.percentUsed, 100)
        XCTAssertEqual(displayPercent(bucket.percentUsed, mode: .left).value, 0)
        XCTAssertEqual(bucket.remainingFraction, 0)
    }
}
