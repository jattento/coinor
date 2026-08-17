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

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The Telegram bot token is empty."
        case let .keychain(status):
            return "Conan Code could not store the Telegram bot token (Keychain status \(status))."
        }
    }
}
