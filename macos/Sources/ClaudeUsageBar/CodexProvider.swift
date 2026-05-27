import Foundation

@MainActor
final class CodexProvider: ObservableObject, UsageProvider {
    @Published private(set) var snapshot: NormalizedUsageSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    let displayName = "Codex"
    let pollInterval: TimeInterval = 5 * 60

    private let adapter: CodexAppServerQuotaAdapter
    private var timer: Timer?

    init(adapter: CodexAppServerQuotaAdapter = CodexAppServerQuotaAdapter()) {
        self.adapter = adapter
    }

    func startPolling() {
        Task { await refresh() }
        scheduleTimer()
    }

    func refresh() async {
        isRefreshing = true
        let result = await fetch()
        switch result {
        case .available(let snapshot):
            self.snapshot = snapshot
            lastUpdated = snapshot.updatedAt
            lastError = nil
        case .unavailable(let message):
            lastError = message
        }
        isRefreshing = false
    }

    func fetch() async -> UsageProviderFetchResult {
        do {
            return .available(try await adapter.fetchSnapshot())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct CodexAppServerQuotaAdapter {
    enum AdapterError: LocalizedError {
        case processLaunchFailed(String)
        case processFailed(String)
        case timeout
        case rpcError(String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .processLaunchFailed(let message):
                return "Codex unavailable: \(message)"
            case .processFailed(let message):
                return "Codex unavailable: \(message)"
            case .timeout:
                return "Codex unavailable: request timed out"
            case .rpcError(let message):
                return "Codex unavailable: \(message)"
            case .malformedResponse(let message):
                return "Codex unavailable: \(message)"
            }
        }
    }

    private let timeout: TimeInterval
    private let executableURL: URL?

    init(timeout: TimeInterval = 10, executableURL: URL? = CodexCommandLocator.executableURL()) {
        self.timeout = timeout
        self.executableURL = executableURL
    }

    func fetchSnapshot() async throws -> NormalizedUsageSnapshot {
        try await Task.detached(priority: .utility) {
            try fetchSnapshotBlocking()
        }.value
    }

    private func fetchSnapshotBlocking() throws -> NormalizedUsageSnapshot {
        let process = Process()
        if let executableURL {
            process.executableURL = executableURL
            process.arguments = ["app-server", "--listen", "stdio://"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex", "app-server", "--listen", "stdio://"]
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let state = CodexJSONRPCState()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.appendOutput(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.appendError(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw AdapterError.processLaunchFailed(error.localizedDescription)
        }

        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        try writeRequests(to: stdin.fileHandleForWriting)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = state.rpcError {
                throw AdapterError.rpcError(error)
            }
            if let rateLimits = state.rateLimitsResult,
               let account = state.accountResult {
                return try Self.mapSnapshot(rateLimitsResult: rateLimits, accountResult: account)
            }
            if process.isRunning == false, state.rateLimitsResult == nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if let error = state.rpcError {
            throw AdapterError.rpcError(error)
        }
        if process.isRunning == false {
            let message = state.stderrText.isEmpty ? "app-server exited with code \(process.terminationStatus)" : state.stderrText
            throw AdapterError.processFailed(message)
        }
        throw AdapterError.timeout
    }

    private func writeRequests(to stdin: FileHandle) throws {
        // account/rateLimits/read is an internal, undocumented Codex app-server method and may change.
        let lines = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-usage-bar","title":"Claude Usage Bar","version":"0.0.0"},"capabilities":null}}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
            #"{"id":3,"method":"account/read","params":{}}"#
        ]

        let payload = lines.joined(separator: "\n") + "\n"
        try stdin.write(contentsOf: Data(payload.utf8))
    }

    static func mapSnapshot(
        rateLimitsResult: [String: Any],
        accountResult: [String: Any],
        now: Date = Date()
    ) throws -> NormalizedUsageSnapshot {
        let rateLimits = selectedRateLimits(from: rateLimitsResult)

        let primaryWindow = window(from: rateLimits, preferredDuration: 300, fallbackKey: "primary")
        let secondaryWindow = window(from: rateLimits, preferredDuration: 10080, fallbackKey: "secondary")

        let account = accountResult["account"] as? [String: Any]
        let accountEmail = account?["email"] as? String
        let accountPlan = account?["planType"] as? String
        let quotaPlan = rateLimits["planType"] as? String

        return NormalizedUsageSnapshot(
            displayName: "Codex",
            primaryBucket: primaryWindow.map { bucket(label: "5h", window: $0) },
            secondaryBucket: secondaryWindow.map { bucket(label: "Weekly", window: $0) },
            credits: credits(from: rateLimits["credits"] as? [String: Any]),
            plan: accountPlan ?? quotaPlan,
            account: accountEmail,
            model: nil,
            updatedAt: now
        )
    }

    private static func selectedRateLimits(from result: [String: Any]) -> [String: Any] {
        if let byLimitId = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byLimitId["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any] ?? [:]
    }

    private static func window(
        from rateLimits: [String: Any],
        preferredDuration: Int,
        fallbackKey: String
    ) -> [String: Any]? {
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any] else { continue }
            if intValue(window["windowDurationMins"]) == preferredDuration {
                return window
            }
        }
        return rateLimits[fallbackKey] as? [String: Any]
    }

    private static func bucket(label: String, window: [String: Any]) -> NormalizedUsageBucket {
        let usedPercent = doubleValue(window["usedPercent"])
        let clampedUsed = usedPercent.map { max(0, min(100, $0)) }
        let percentLeft = clampedUsed.map { 100.0 - $0 }
        let resetsAt = doubleValue(window["resetsAt"])
            .map { Date(timeIntervalSince1970: $0) }

        return NormalizedUsageBucket(
            label: label,
            percentLeft: percentLeft,
            progressFraction: percentLeft.map { max(0, min(1, $0 / 100.0)) },
            consumedFraction: clampedUsed.map { max(0, min(1, $0 / 100.0)) },
            resetsAt: resetsAt,
            displayMode: .left
        )
    }

    private static func credits(from payload: [String: Any]?) -> NormalizedCredits? {
        guard let payload else { return nil }
        let unlimited = boolValue(payload["unlimited"]) ?? false
        let balance = decimalValue(payload["balance"])

        return NormalizedCredits(
            label: "Credits",
            balance: balance,
            unlimited: unlimited
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return Bool(value)
        default:
            return nil
        }
    }

    private static func decimalValue(_ value: Any?) -> Decimal? {
        switch value {
        case let value as Decimal:
            return value
        case let value as NSNumber:
            return value.decimalValue
        case let value as String:
            let number = NSDecimalNumber(string: value)
            return number == .notANumber ? nil : number.decimalValue
        default:
            return nil
        }
    }
}

private final class CodexJSONRPCState {
    private let lock = NSLock()
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private(set) var rateLimitsResult: [String: Any]?
    private(set) var accountResult: [String: Any]?
    private(set) var rpcError: String?

    var stderrText: String {
        lock.withLock {
            String(data: errorBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    func appendOutput(_ data: Data) {
        guard data.isEmpty == false else { return }
        lock.withLock {
            outputBuffer.append(data)
            parseAvailableLines()
        }
    }

    func appendError(_ data: Data) {
        guard data.isEmpty == false else { return }
        lock.withLock {
            errorBuffer.append(data)
        }
    }

    private func parseAvailableLines() {
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            parseLine(Data(line))
        }
    }

    private func parseLine(_ data: Data) {
        guard data.isEmpty == false,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard let id = responseID(from: object["id"]) else { return }

        if let error = object["error"] as? [String: Any] {
            rpcError = (error["message"] as? String) ?? "JSON-RPC request failed"
            return
        }

        guard let result = object["result"] as? [String: Any] else { return }
        switch id {
        case 2:
            rateLimitsResult = result
        case 3:
            accountResult = result
        default:
            break
        }
    }

    private func responseID(from value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}

private enum CodexCommandLocator {
    static func executableURL(fileManager: FileManager = .default) -> URL? {
        [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
