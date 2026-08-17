import Foundation
import Security

protocol TelegramTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

final class MemoryTelegramTokenStore: TelegramTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func load() throws -> String? {
        lock.withLock { token }
    }

    func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    func delete() throws {
        lock.withLock { token = nil }
    }
}

/// Bot token on disk at `~/.coinor/telegram.toml`, mode 0600.
///
/// Keychain access prompts on every read. This file is still private to
/// this Mac and never part of the public repository.
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
        if let token = try readFile() {
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

    func save(_ token: String) throws {
        let trimmed = Self.normalized(token)
        guard !trimmed.isEmpty else {
            throw TelegramCredentialError.emptyToken
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let body = """
        # Private to this Mac. Do not commit or share.
        bot_token = "\(trimmed)"
        
        """
        do {
            try Data(body.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw TelegramCredentialError.unwritable(error.localizedDescription)
        }
        try? migrateFrom?.delete()
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? migrateFrom?.delete()
            return
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw TelegramCredentialError.unwritable(error.localizedDescription)
        }
        try? migrateFrom?.delete()
    }

    private func readFile() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw TelegramCredentialError.unreadable(error.localizedDescription)
        }
        return Self.parse(raw)
    }

    static func parse(_ raw: String) -> String? {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if lines.count == 1, !lines[0].contains("=") {
            return normalized(String(lines[0]))
        }
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "bot_token" else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            return normalized(String(value))
        }
        return nil
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
