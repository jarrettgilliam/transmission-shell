import Foundation
import Observation
import TransmissionKit
import os

/// How a write-only password field should be applied on save.
enum PasswordChange {
    case unchanged
    case set(String)
    case remove
}

/// Owns the persisted server settings and the client built from them.
///
/// `RPCClient` caches the password it was constructed with, so every save builds a new
/// one rather than mutating the old.
@MainActor
@Observable
final class AppModel {
    private(set) var config: ServerConfig?
    private(set) var client: RPCClient?

    @ObservationIgnored private let configStore: any ServerConfigStore
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let logger = Logger(
        subsystem: InstallationIdentity.current,
        category: "AppModel"
    )

    init(
        configStore: any ServerConfigStore = UserDefaultsServerConfigStore.transmissionShell,
        credentials: any CredentialStore = CachingCredentialStore(KeychainCredentialStore())
    ) {
        self.configStore = configStore
        self.credentials = credentials
    }

    var isConfigured: Bool { config != nil }

    var hasStoredPassword: Bool {
        (try? credentials.hasPassword()) ?? false
    }

    func load() {
        do {
            config = try configStore.load()
        } catch {
            logger.error("Discarding unreadable config: \(error.localizedDescription, privacy: .public)")
            config = nil
        }
        rebuildClient()
    }

    /// Persists the settings and replaces ``client``. Throws ``ConfigError`` if
    /// `urlString` isn't a usable address, in which case nothing is written.
    func save(
        urlString: String,
        username: String?,
        password: PasswordChange,
        allowsInvalidCertificates: Bool
    ) throws {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespaces)
        let newConfig = try ServerConfig(
            urlString: urlString,
            username: (trimmedUsername?.isEmpty ?? true) ? nil : trimmedUsername,
            allowsInvalidCertificates: allowsInvalidCertificates
        )

        switch password {
        case .unchanged:
            break
        case .set(let value):
            try credentials.setPassword(value)
        case .remove:
            try credentials.setPassword(nil)
        }

        try configStore.save(newConfig)
        config = newConfig
        rebuildClient()
    }

    /// Builds a client for settings that haven't been saved, so Test Connection reports
    /// on what's on screen rather than on what's stored.
    func probeClient(
        urlString: String,
        username: String?,
        password: PasswordChange,
        allowsInvalidCertificates: Bool
    ) throws -> RPCClient {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespaces)
        let probeConfig = try ServerConfig(
            urlString: urlString,
            username: (trimmedUsername?.isEmpty ?? true) ? nil : trimmedUsername,
            allowsInvalidCertificates: allowsInvalidCertificates
        )

        let probePassword: String?
        switch password {
        case .unchanged: probePassword = try credentials.password()
        case .set(let value): probePassword = value
        case .remove: probePassword = nil
        }

        return RPCClient(
            config: probeConfig,
            credentials: InMemoryCredentialStore(password: probePassword),
            transport: URLSessionTransport(allowsInvalidCertificates: probeConfig.allowsInvalidCertificates)
        )
    }

    /// `nil` when nothing is configured yet.
    func webCredential() -> URLCredential? {
        guard let username = config?.username, !username.isEmpty else { return nil }
        let password = (try? credentials.password()) ?? nil
        return URLCredential(user: username, password: password ?? "", persistence: .forSession)
    }

    private func rebuildClient() {
        client = config.map { config in
            RPCClient(
                config: config,
                credentials: credentials,
                transport: URLSessionTransport(allowsInvalidCertificates: config.allowsInvalidCertificates)
            )
        }
    }
}

extension Bundle {
    /// Falls back to the name the app ships with, since `swift run` has no bundle.
    static let transmissionShellName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Transmission Shell"
}
