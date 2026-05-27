import Foundation

struct ProviderNotificationSettings: Codable, Equatable {
    var fiveHourThresholdPct: Int?
    var weeklyThresholdPct: Int?
    var extraUsageEnabled: Bool

    static let off = ProviderNotificationSettings(
        fiveHourThresholdPct: nil,
        weeklyThresholdPct: nil,
        extraUsageEnabled: false
    )
}

enum UsageProviderID {
    static let claude = "claude"
    static let codex = "codex"
}
