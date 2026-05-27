import XCTest
@testable import AgentUsageBar

final class AppConfigMigrationTests: XCTestCase {
    func testMigratesOldConfigDirectoryWhenNewDirectoryIsAbsent() throws {
        let root = try makeConfigRoot()
        let oldDirectory = root.appendingPathComponent("claude-usage-bar", isDirectory: true)
        let newDirectory = root.appendingPathComponent("agent-usage-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try "token".write(to: oldDirectory.appendingPathComponent("token"), atomically: true, encoding: .utf8)

        var logs: [String] = []
        AppConfigMigration.migrateIfNeeded(configRoot: root, log: { logs.append($0) })

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("token").path))
        XCTAssertTrue(logs.contains { $0.contains("migrated config directory") })
    }

    func testDoesNotOverwriteExistingNewConfigDirectory() throws {
        let root = try makeConfigRoot()
        let oldDirectory = root.appendingPathComponent("claude-usage-bar", isDirectory: true)
        let newDirectory = root.appendingPathComponent("agent-usage-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)

        AppConfigMigration.migrateIfNeeded(configRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDirectory.path))
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
