import Foundation
import Synchronization
import Security

/// Storage for the daemon password. There is only ever one, since the app targets a
/// single server.
public protocol CredentialStore: Sendable {
    /// `nil` when no password has been stored.
    func password() throws -> String?

    /// Passing `nil` removes the stored password.
    func setPassword(_ password: String?) throws
}

/// Keeps the password in the login keychain as one generic-password item whose identity
/// never changes, so editing the server address or username is an in-place update rather
/// than a delete-and-rewrite that could orphan items.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.jarrettgilliam.transmission-shell", account: String = "daemon-password") {
        self.service = service
        self.account = account
    }

    public func password() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unreadableItem
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setPassword(_ password: String?) throws {
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(password.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case unreadableItem

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        case .unreadableItem:
            return "The stored password could not be read."
        }
    }
}

/// Keeps the password in memory only. For tests and SwiftUI previews, which must not
/// touch the real keychain.
public final class InMemoryCredentialStore: CredentialStore {
    private let storage = Mutex<String?>(nil)

    public init(password: String? = nil) {
        storage.withLock { $0 = password }
    }

    public func password() throws -> String? {
        storage.withLock { $0 }
    }

    public func setPassword(_ password: String?) throws {
        storage.withLock { $0 = password }
    }
}
