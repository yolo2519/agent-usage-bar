import Foundation
import SwiftUI

@MainActor
protocol UsageProvider {
    var displayName: String { get }
    var pollInterval: TimeInterval { get }

    func fetch() async -> UsageProviderFetchResult
}

enum UsageProviderFetchResult {
    case available(NormalizedUsageSnapshot)
    case unavailable(String)
}

struct NormalizedUsageSnapshot {
    let displayName: String
    let primaryBucket: NormalizedUsageBucket?
    let secondaryBucket: NormalizedUsageBucket?
    let credits: NormalizedCredits?
    let plan: String?
    let account: String?
    let model: String?
    let updatedAt: Date

    var quotaHealth: QuotaHealth? {
        QuotaHealth.worst([
            primaryBucket?.quotaHealth,
            secondaryBucket?.quotaHealth
        ])
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case used
    case left

    var id: String { rawValue }
}

enum QuotaHealth: Equatable {
    case healthy
    case caution
    case warning
    case critical

    static func from(percentLeft: Int) -> QuotaHealth {
        switch percentLeft {
        case 51...:
            return .healthy
        case 20...50:
            return .caution
        case 10..<20:
            return .warning
        default:
            return .critical
        }
    }

    static func worst(_ values: [QuotaHealth?]) -> QuotaHealth? {
        values.compactMap { $0 }.max { $0.severity < $1.severity }
    }

    var severity: Int {
        switch self {
        case .healthy:
            return 0
        case .caution:
            return 1
        case .warning:
            return 2
        case .critical:
            return 3
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            return .green
        case .caution:
            return .yellow
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .healthy:
            return "checkmark.circle.fill"
        case .caution:
            return "exclamationmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.octagon.fill"
        }
    }
}

func displayPercent(_ used: Int, mode: UsageDisplayMode) -> (value: Int, suffix: String) {
    switch mode {
    case .used:
        return (used, "%")
    case .left:
        return (100 - used, "% left")
    }
}

struct NormalizedUsageBucket {
    let label: String
    let percentUsed: Int
    let resetsAt: Date?

    var remainingFraction: Double {
        Double(percentLeft) / 100.0
    }

    var percentLeft: Int {
        100 - percentUsed
    }

    var quotaHealth: QuotaHealth {
        QuotaHealth.from(percentLeft: percentLeft)
    }

    init(label: String, percentUsed: Int, resetsAt: Date?) {
        self.label = label
        self.percentUsed = max(0, min(100, percentUsed))
        self.resetsAt = resetsAt
    }
}

struct NormalizedCredits {
    let label: String
    let balance: Decimal?
    let unlimited: Bool
}
