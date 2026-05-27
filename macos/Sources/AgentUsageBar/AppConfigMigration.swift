import Foundation

enum AppConfigMigration {
    static let oldConfigDirectoryName = "claude-usage-bar"
    static let configDirectoryName = "agent-usage-bar"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(configDirectoryName)", isDirectory: true)
    }

    static func migrateIfNeeded(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        let configRoot = home.appendingPathComponent(".config", isDirectory: true)
        migrateIfNeeded(configRoot: configRoot, fileManager: fileManager)
    }

    static func migrateIfNeeded(
        configRoot: URL,
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) {
        let oldDirectory = configRoot.appendingPathComponent(oldConfigDirectoryName, isDirectory: true)
        let newDirectory = configRoot.appendingPathComponent(configDirectoryName, isDirectory: true)

        guard fileManager.fileExists(atPath: oldDirectory.path) else { return }
        guard !fileManager.fileExists(atPath: newDirectory.path) else { return }

        do {
            try fileManager.moveItem(at: oldDirectory, to: newDirectory)
            log("Agent Usage Bar: migrated config directory from \(oldDirectory.path) to \(newDirectory.path)")
        } catch {
            log("Agent Usage Bar: warning: could not migrate config directory from \(oldDirectory.path) to \(newDirectory.path): \(error)")
        }
    }
}
