import Foundation
import Security

struct AppSecretStore: Sendable {
    let loadValue: @Sendable (String) -> String?
    let saveValue: @Sendable (String, String) -> Void

    func load(key: String) -> String? {
        loadValue(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    /// File-backed store at `~/Library/Application Support/OpenOats/secrets.json`
    /// (file mode 0600). Replaces the previous Keychain-backed store — Keychain's
    /// ACL prompts on every unsigned-build launch were unworkable for local dev.
    /// Plain JSON is fine in practice: FileVault encrypts at rest, and 0600 keeps
    /// other Unix users on the same Mac out.
    static let fileBacked = AppSecretStore(
        loadValue: { FileSecretStore.load(key: $0) },
        saveValue: { key, value in
            FileSecretStore.save(key: key, value: value)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct SettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> SettingsStorage {
        SettingsStorage(
            defaults: defaults,
            secretStore: .fileBacked,
            defaultNotesDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/OpenOats"),
            runMigrations: true
        )
    }
}

/// Backward-compatible alias for existing test code.
typealias AppSettingsStorage = SettingsStorage

// MARK: - File-Backed Secret Store

enum FileSecretStore {
    private static let directoryName = "OpenOats"
    private static let fileName = "secrets.json"
    private static let lock = NSLock()

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent(directoryName, isDirectory: true)
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return readDict()[key]
    }

    static func save(key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = readDict()
        dict[key] = value
        writeDict(dict)
    }

    static func delete(key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = readDict()
        guard dict.removeValue(forKey: key) != nil else { return }
        writeDict(dict)
    }

    private static func readDict() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeDict(_ dict: [String: String]) {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(dict)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Match the prior Keychain helper's swallow-on-failure behavior.
        }
    }
}
