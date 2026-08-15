import Foundation
import Synchronization

/// Storage for the non-secret half of the server settings.
public protocol ServerConfigStore: Sendable {
    /// `nil` before the user has configured anything.
    func load() throws -> ServerConfig?

    func save(_ config: ServerConfig) throws
}

/// Unchecked because `UserDefaults` is thread-safe but predates `Sendable` annotation.
public struct UserDefaultsServerConfigStore: ServerConfigStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "serverConfig") {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> ServerConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }

    public func save(_ config: ServerConfig) throws {
        defaults.set(try JSONEncoder().encode(config), forKey: key)
    }

    /// The app's own settings domain. Keeps `swift run` out of the installed app's
    /// settings, and vice versa.
    public static let transmissionShell = UserDefaultsServerConfigStore(
        defaults: UserDefaults(suiteName: InstallationIdentity.settingsSuite) ?? .standard
    )
}

/// For tests and SwiftUI previews, which must not touch the real defaults domain.
public final class InMemoryServerConfigStore: ServerConfigStore {
    private let storage = Mutex<ServerConfig?>(nil)

    public init(config: ServerConfig? = nil) {
        storage.withLock { $0 = config }
    }

    public func load() throws -> ServerConfig? {
        storage.withLock { $0 }
    }

    public func save(_ config: ServerConfig) throws {
        storage.withLock { $0 = config }
    }
}
