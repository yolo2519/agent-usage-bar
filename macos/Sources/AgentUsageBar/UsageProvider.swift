import Foundation

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
}

struct NormalizedUsageBucket {
    enum DisplayMode {
        case used
        case left
    }

    let label: String
    let percentLeft: Double?
    let progressFraction: Double?
    let consumedFraction: Double?
    let resetsAt: Date?
    let displayMode: DisplayMode

    var percentageText: String {
        switch displayMode {
        case .used:
            guard let consumedFraction else { return "-" }
            return "\(Int(round(consumedFraction * 100)))%"
        case .left:
            guard let percentLeft else { return "-" }
            return "\(Int(round(percentLeft)))% left"
        }
    }
}

struct NormalizedCredits {
    let label: String
    let balance: Decimal?
    let unlimited: Bool
}
