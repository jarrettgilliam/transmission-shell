import Foundation

/// Connection settings for a single Transmission daemon.
///
/// `baseURL` mirrors the daemon's own `rpc-url` setting: the directory beneath which
/// `rpc` and `web/` are served. It is always normalized (see ``init(urlString:username:allowsInvalidCertificates:)``),
/// including when decoded, so a value of this type is always usable as-is.
///
/// The password is never held here; see ``CredentialStore``.
public struct ServerConfig: Codable, Sendable, Equatable {
    public let baseURL: URL

    /// `nil` or empty means the daemon has authentication disabled and no
    /// `Authorization` header should be sent.
    public var username: String?

    public var allowsInvalidCertificates: Bool

    public static let defaultURLString = "http://localhost:9091/transmission/"

    /// Normalizes `urlString` and rejects what can't be a Transmission endpoint.
    ///
    /// Normalization: a missing scheme becomes `http`; a missing port is left missing,
    /// meaning the scheme's default; a trailing `index.html`, `web`, or `rpc` component
    /// is dropped, so a URL copied from the browser's address bar works; an absent path
    /// becomes `/transmission/`; the path always ends in a slash. Query, fragment, and
    /// userinfo are discarded.
    ///
    /// Throws ``ConfigError``.
    public init(urlString: String, username: String? = nil, allowsInvalidCertificates: Bool = false) throws {
        self.baseURL = try Self.normalize(urlString)
        self.username = username
        self.allowsInvalidCertificates = allowsInvalidCertificates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            urlString: container.decode(String.self, forKey: .baseURL),
            username: container.decodeIfPresent(String.self, forKey: .username),
            allowsInvalidCertificates: container.decodeIfPresent(Bool.self, forKey: .allowsInvalidCertificates) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL.absoluteString, forKey: .baseURL)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encode(allowsInvalidCertificates, forKey: .allowsInvalidCertificates)
    }

    public var rpcURL: URL {
        baseURL.appending(path: "rpc", directoryHint: .notDirectory)
    }

    public var webURL: URL {
        baseURL.appending(path: "web", directoryHint: .isDirectory)
    }

    /// `nil` when no username is set, i.e. when the daemon has auth disabled.
    public func authorizationHeader(password: String?) -> String? {
        guard let username, !username.isEmpty else { return nil }
        let credentials = "\(username):\(password ?? "")"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    private static func normalize(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigError.empty }

        let qualified = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: qualified) else { throw ConfigError.malformed(trimmed) }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ConfigError.unsupportedScheme(components.scheme ?? "")
        }
        guard let host = components.host, !host.isEmpty else { throw ConfigError.missingHost }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last?.lowercased() == "index.html" { segments.removeLast() }
        if let last = segments.last?.lowercased(), last == "web" || last == "rpc" { segments.removeLast() }
        components.path = segments.isEmpty ? "/transmission/" : "/\(segments.joined(separator: "/"))/"

        guard let url = components.url else { throw ConfigError.malformed(trimmed) }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, username, allowsInvalidCertificates
    }
}

public enum ConfigError: Error, Equatable, LocalizedError {
    case empty
    case malformed(String)
    case missingHost
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter the address of your Transmission server."
        case .malformed(let text):
            "“\(text)” isn’t a valid address."
        case .missingHost:
            "The address is missing a host name."
        case .unsupportedScheme(let scheme):
            "“\(scheme)” isn’t supported; use http or https."
        }
    }
}
