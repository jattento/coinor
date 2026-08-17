import Foundation
import Security

protocol TelegramTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
    func allowedUsername() throws -> String?
}

final class MemoryTelegramTokenStore: TelegramTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var username: String?

    func load() throws -> String? {
        lock.withLock { token }
    }

    func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    func delete() throws {
        lock.withLock { token = nil }
    }

    func allowedUsername() throws -> String? {
        lock.withLock { username }
    }

    func setAllowedUsername(_ username: String?) {
        lock.withLock { self.username = username }
    }
}

/// Bot token on disk at `~/.coinor/telegram.toml`, mode 0600.
///
/// Keychain access prompts on every read. This file is still private to
/// this Mac and never part of the public repository.
struct TelegramHomeConfig: Equatable, Sendable {
    var botToken: String?
    var allowedUsername: String?

    var serialized: String {
        var lines = [
            "# Private to this Mac. Do not commit or share.",
        ]
        if let botToken, !botToken.isEmpty {
            lines.append("bot_token = \"\(botToken)\"")
        }
        if let allowedUsername, !allowedUsername.isEmpty {
            lines.append("allowed_username = \"\(allowedUsername)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct FileTelegramTokenStore: TelegramTokenStoring {
    var fileURL: URL
    var migrateFrom: (any TelegramTokenStoring)?

    static let relativePath = ".coinor/telegram.toml"

    static var `default`: FileTelegramTokenStore {
        FileTelegramTokenStore(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath),
            migrateFrom: KeychainTelegramTokenStore.default
        )
    }

    func load() throws -> String? {
        if let token = try readConfig().botToken, !token.isEmpty {
            return token
        }
        guard let migrated = try migrateFrom?.load(),
              !migrated.isEmpty else {
            return nil
        }
        try save(migrated)
        try? migrateFrom?.delete()
        return migrated
    }

    func allowedUsername() throws -> String? {
        try readConfig().allowedUsername
    }

    func save(_ token: String) throws {
        let trimmed = Self.normalized(token)
        guard !trimmed.isEmpty else {
            throw TelegramCredentialError.emptyToken
        }
        var config = try readConfig()
        config.botToken = trimmed
        try write(config)
        try? migrateFrom?.delete()
    }

    func saveAllowedUsername(_ username: String?) throws {
        var config = try readConfig()
        let normalized = username.map(TelegramUsername.normalize) ?? ""
        config.allowedUsername = normalized.isEmpty ? nil : normalized
        try write(config)
    }

    func delete() throws {
        var config = try readConfig()
        config.botToken = nil
        if config.allowedUsername == nil {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    throw TelegramCredentialError.unwritable(error.localizedDescription)
                }
            }
        } else {
            try write(config)
        }
        try? migrateFrom?.delete()
    }

    private func readConfig() throws -> TelegramHomeConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TelegramHomeConfig()
        }
        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw TelegramCredentialError.unreadable(error.localizedDescription)
        }
        return Self.parseConfig(raw)
    }

    private func write(_ config: TelegramHomeConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        do {
            try Data(config.serialized.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw TelegramCredentialError.unwritable(error.localizedDescription)
        }
    }

    static func parse(_ raw: String) -> String? {
        parseConfig(raw).botToken
    }

    static func parseConfig(_ raw: String) -> TelegramHomeConfig {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if lines.count == 1, !lines[0].contains("=") {
            return TelegramHomeConfig(botToken: normalized(String(lines[0])))
        }
        var config = TelegramHomeConfig()
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = normalized(
                String(line[line.index(after: separator)...])
            )
            guard !value.isEmpty else { continue }
            switch key {
            case "bot_token":
                config.botToken = value
            case "allowed_username", "telegram_user", "username":
                config.allowedUsername = TelegramUsername.normalize(value)
            default:
                continue
            }
        }
        return config
    }

    static func normalized(_ token: String) -> String {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct KeychainTelegramTokenStore: TelegramTokenStoring {
    var service: String
    var account: String

    static let `default` = KeychainTelegramTokenStore(
        service: "dev.coinor.Coinor.telegram",
        account: "bot-token"
    )

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TelegramCredentialError.keychain(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    func allowedUsername() throws -> String? {
        nil
    }

    func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramCredentialError.emptyToken
        }
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TelegramCredentialError.keychain(status)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TelegramCredentialError.keychain(status)
        }
    }
}

enum TelegramCredentialError: Error, Equatable, LocalizedError, Sendable {
    case emptyToken
    case keychain(OSStatus)
    case unreadable(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The Telegram bot token is empty."
        case let .keychain(status):
            return "Conan Code could not store the Telegram bot token (Keychain status \(status))."
        case let .unreadable(detail):
            return "Conan Code could not read ~/.coinor/telegram.toml: \(detail)"
        case let .unwritable(detail):
            return "Conan Code could not write ~/.coinor/telegram.toml: \(detail)"
        }
    }
}
