import Foundation
import Observation
import TransmissionKit
import os

/// How a write-only password field should be applied on save.
enum PasswordChange {
    case unchanged
    case set(String)

    var typed: String? {
        switch self {
        case .unchanged: nil
        case .set(let value): value
        }
    }
}

/// Owns the persisted server settings and the client built from them.
///
/// `RPCClient` caches the login it was constructed with, so every save builds a new one
/// rather than mutating the old.
@MainActor
@Observable
final class AppModel {
    private(set) var config: ServerConfig?
    private(set) var client: RPCClient?

    /// The store for ``config``. `nil` until something is configured.
    private(set) var credentials: (any CredentialStore)?

    @ObservationIgnored private let configStore: any ServerConfigStore
    @ObservationIgnored private let makeCredentials: (ServerConfig) -> any CredentialStore
    @ObservationIgnored private let logger = Logger(
        subsystem: InstallationIdentity.current,
        category: "AppModel"
    )

    /// The credential store depends on the server it belongs to, so it arrives as a factory
    /// rather than an instance.
    init(
        configStore: any ServerConfigStore = UserDefaultsServerConfigStore.transmissionShell,
        credentials: @escaping (ServerConfig) -> any CredentialStore = {
            CachingCredentialStore(InternetPasswordCredentialStore(config: $0))
        }
    ) {
        self.configStore = configStore
        self.makeCredentials = credentials
    }

    var isConfigured: Bool { config != nil }

    func load() {
        do {
            config = try configStore.load()
        } catch {
            logger.error("Discarding unreadable config: \(error.localizedDescription, privacy: .public)")
            config = nil
        }
        rebuildClient()
    }

    /// Drops the cached login so the next read picks up a password changed in a browser or
    /// in Keychain Access. A read, not a prompt: the item's ACL already knows this build.
    func invalidateCredentialCache() {
        guard let credentials else { return }
        credentials.invalidate()
        // The client caches the header it built from the old login, so dropping the store's
        // cache alone would change nothing for RPC.
        rebuildClient(reusing: credentials)
    }

    /// Persists the settings and replaces ``client``. Throws ``ConfigError`` if `urlString`
    /// isn't a usable address, or ``CredentialFormError`` if the two credential boxes don't
    /// amount to a login; nothing is written in either case.
    func save(
        urlString: String,
        username: String,
        password: PasswordChange,
        allowsInvalidCertificates: Bool
    ) throws {
        let newConfig = try ServerConfig(
            urlString: urlString,
            allowsInvalidCertificates: allowsInvalidCertificates
        )

        let store = credentialStore(for: newConfig)
        let resolved = try resolveCredential(username: username, password: password.typed, in: store)
        if let resolved, resolved.needsWrite {
            try store.setCredential(username: resolved.username, password: resolved.password)
        }

        try configStore.save(newConfig)
        config = newConfig
        rebuildClient(reusing: store)
    }

    /// Builds a client for settings that haven't been saved, so Test Connection reports on
    /// what's on screen rather than on what's stored.
    func probeClient(
        urlString: String,
        username: String,
        password: PasswordChange,
        allowsInvalidCertificates: Bool
    ) throws -> RPCClient {
        let probeConfig = try ServerConfig(
            urlString: urlString,
            allowsInvalidCertificates: allowsInvalidCertificates
        )

        let resolved = try resolveCredential(
            username: username,
            password: password.typed,
            in: credentialStore(for: probeConfig)
        )

        return RPCClient(
            config: probeConfig,
            credentials: InMemoryCredentialStore(
                username: resolved?.username,
                password: resolved?.password ?? ""
            ),
            transport: URLSessionTransport(allowsInvalidCertificates: probeConfig.allowsInvalidCertificates)
        )
    }

    /// What Settings shows for `urlString`: the account on the item that would be used, and
    /// whether one exists at all. Both are attribute-only lookups, so neither prompts. `nil`
    /// when the string isn't a usable address.
    func storedLogin(forURLString urlString: String) -> (username: String?, exists: Bool)? {
        guard let config = try? ServerConfig(urlString: urlString) else { return nil }
        let store = credentialStore(for: config)
        return (username: (try? store.username()) ?? nil, exists: (try? store.hasCredential()) ?? false)
    }

    /// `nil` when nothing is stored for the configured server, which cancels the web view's
    /// auth challenge. A login with an empty password is offered rather than cancelled.
    func webCredential() -> URLCredential? {
        guard let credentials, let login = (try? credentials.credential()) ?? nil else { return nil }
        return URLCredential(user: login.username, password: login.password, persistence: .forSession)
    }

    /// Reuses the live store when the identity matches, so Settings reads through its warm
    /// cache instead of paying a fresh keychain read.
    private func credentialStore(for config: ServerConfig) -> any CredentialStore {
        if config.baseURL == self.config?.baseURL, let credentials { return credentials }
        return makeCredentials(config)
    }

    private func rebuildClient(reusing store: (any CredentialStore)? = nil) {
        guard let config else {
            credentials = nil
            client = nil
            return
        }

        let store = store ?? makeCredentials(config)
        credentials = store
        client = RPCClient(
            config: config,
            credentials: store,
            transport: URLSessionTransport(allowsInvalidCertificates: config.allowsInvalidCertificates)
        )
    }
}

extension Bundle {
    /// Falls back to the name the app ships with, since `swift run` has no bundle.
    static let transmissionShellName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Transmission Shell"
}
