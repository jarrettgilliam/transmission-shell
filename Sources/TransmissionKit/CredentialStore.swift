import Foundation
import Synchronization
import Security

/// Storage for the daemon login. There is only ever one, since the app targets a single
/// server and `tr_rpc_server` holds a single username and password.
public protocol CredentialStore: Sendable {
    /// `nil` when no login has been stored. An empty password is a valid login.
    func credential() throws -> (username: String, password: String)?

    /// Replaces the stored login, including its username.
    func setCredential(username: String, password: String) throws

    /// Whether a login is stored, without reading its password.
    func hasCredential() throws -> Bool

    /// The stored username, without reading the password. `nil` when nothing is stored.
    func username() throws -> String?

    /// Drops anything cached, so the next read sees changes made outside the app.
    func invalidate()
}

extension CredentialStore {
    public func hasCredential() throws -> Bool {
        try credential() != nil
    }

    public func username() throws -> String? {
        try credential()?.username
    }

    public func invalidate() {}
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

/// Reads the wrapped store at most once per process, until ``invalidate()``.
///
/// Every keychain read is a separate ACL check, and an app the keychain doesn't recognise
/// gets one password prompt per check. One read means at most one prompt.
public final class CachingCredentialStore: CredentialStore {
    private let wrapped: any CredentialStore
    private let cached = Mutex<(username: String, password: String)??>(nil)

    public init(_ wrapped: any CredentialStore) {
        self.wrapped = wrapped
    }

    public func credential() throws -> (username: String, password: String)? {
        try cached.withLock { slot in
            if let slot { return slot }
            let value = try wrapped.credential()
            slot = value
            return value
        }
    }

    public func setCredential(username: String, password: String) throws {
        try wrapped.setCredential(username: username, password: password)
        cached.withLock { $0 = .some((username: username, password: password)) }
    }

    public func hasCredential() throws -> Bool {
        try cached.withLock { slot in
            if let slot { return slot != nil }
            return try wrapped.hasCredential()
        }
    }

    public func username() throws -> String? {
        try cached.withLock { slot in
            if let slot { return slot?.username }
            return try wrapped.username()
        }
    }

    public func invalidate() {
        cached.withLock { $0 = nil }
        wrapped.invalidate()
    }
}

/// Keeps the login in memory only. For tests and SwiftUI previews, which must not touch
/// the real keychain.
public final class InMemoryCredentialStore: CredentialStore {
    private let storage = Mutex<(username: String, password: String)?>(nil)

    public init(username: String? = nil, password: String = "") {
        if let username {
            storage.withLock { $0 = (username: username, password: password) }
        }
    }

    public func credential() throws -> (username: String, password: String)? {
        storage.withLock { $0 }
    }

    public func setCredential(username: String, password: String) throws {
        storage.withLock { $0 = (username: username, password: password) }
    }
}
