import Foundation
import Synchronization
import Security

/// Storage for the daemon password. There is only ever one, since the app targets a
/// single server.
public protocol CredentialStore: Sendable {
    /// `nil` when no password has been stored.
    func password() throws -> String?

    /// Passing `nil` or an empty string removes the stored password.
    func setPassword(_ password: String?) throws

    /// Whether a password is stored, without reading it.
    func hasPassword() throws -> Bool
}

extension CredentialStore {
    public func hasPassword() throws -> Bool {
        try password() != nil
    }

    func normalized(_ password: String?) -> String? {
        (password?.isEmpty ?? true) ? nil : password
    }
}

/// Keeps the password in the login keychain as one generic-password item whose identity
/// never changes, so editing the server address or username is an in-place update rather
/// than a delete-and-rewrite that could orphan items.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = InstallationIdentity.current, account: String = "daemon-password") {
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

    /// Asking for attributes rather than `kSecReturnData` skips the item's ACL check, so
    /// this never raises the "wants to use your confidential information" prompt. Adding
    /// `kSecReturnData` here would.
    public func hasPassword() throws -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
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

/// Reads the wrapped store at most once per process.
///
/// Every keychain read is a separate ACL check, and an app the keychain doesn't recognise
/// gets one password prompt per check. One read means at most one prompt.
public final class CachingCredentialStore: CredentialStore {
    private let wrapped: any CredentialStore
    private let cached = Mutex<String??>(nil)

    public init(_ wrapped: any CredentialStore) {
        self.wrapped = wrapped
    }

    public func password() throws -> String? {
        try cached.withLock { slot in
            if let slot { return slot }
            let value = try wrapped.password()
            slot = value
            return value
        }
    }

    public func setPassword(_ password: String?) throws {
        try wrapped.setPassword(password)
        cached.withLock { $0 = normalized(password) }
    }

    public func hasPassword() throws -> Bool {
        try cached.withLock { slot in
            if let slot { return slot != nil }
            return try wrapped.hasPassword()
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
        let value = normalized(password)
        storage.withLock { $0 = value }
    }
}
