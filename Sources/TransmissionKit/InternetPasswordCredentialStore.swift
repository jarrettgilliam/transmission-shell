import Foundation
import Security

/// Keeps the daemon login in the login keychain as the same website credential a browser
/// writes, so the app and Safari share one item for a given server.
///
/// Sharing is what keeps the app to a single keychain prompt per build: `WKWebView` resolves
/// the protection space against the credential store before the auth challenge reaches the
/// app, so an item of the app's own would be a second item with a second ACL.
public struct InternetPasswordCredentialStore: CredentialStore {
    /// The daemon's realm is `#define MY_REALM "Transmission"` in `libtransmission/rpc-server.cc`
    /// and is not runtime-configurable. A reverse proxy presenting its own realm puts the
    /// browser's item in a different protection space, and sharing stops.
    public static let realm = "Transmission"

    public let server: String
    public let port: Int

    /// `kSecAttrProtocol`: `"http"` or `"htps"`.
    public let networkProtocol: String

    public init(config: ServerConfig) {
        let isHTTPS = config.baseURL.scheme == "https"
        self.server = config.baseURL.host() ?? ""
        self.port = config.baseURL.port ?? (isHTTPS ? 443 : 80)
        self.networkProtocol = (isHTTPS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP) as String
    }

    public func credential() throws -> (username: String, password: String)? {
        guard let account = try selectedAccount() else { return nil }

        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.unreadableItem
            }
            return (username: account, password: password)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func hasCredential() throws -> Bool {
        try selectedAccount() != nil
    }

    public func username() throws -> String? {
        try selectedAccount()
    }

    public func setCredential(username: String, password: String) throws {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: "\(server) (\(username))",
            kSecValueData as String: Data(password.utf8)
        ]

        if let account = try selectedAccount() {
            var query = baseQuery
            query[kSecAttrAccount as String] = account
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            return
        }

        let status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Picks the item every path uses, so a read can't authenticate with one item while a
    /// write updates another.
    ///
    /// Asking for attributes rather than `kSecReturnData` skips the ACL check, so choosing is
    /// free and only reading the password costs a prompt. `kSecMatchLimitOne` without an
    /// account is not an option: it returns an arbitrary item *and* reads its data.
    private func selectedAccount() throws -> String? {
        try Self.select(candidates())?[kSecAttrAccount as String] as? String
    }

    static func select(_ candidates: [[String: Any]]) -> [String: Any]? {
        candidates.sorted { lhs, rhs in
            let lhsDate = lhs[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let rhsDate = rhs[kSecAttrModificationDate as String] as? Date ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            let lhsAccount = lhs[kSecAttrAccount as String] as? String ?? ""
            let rhsAccount = rhs[kSecAttrAccount as String] as? String ?? ""
            return lhsAccount < rhsAccount
        }.first
    }

    private func candidates() throws -> [[String: Any]] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            return items as? [[String: Any]] ?? []
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// No account: the identity is the protection space, and the account is what selection
    /// discovers. `kSecAttrAuthenticationTypeDefault` is what Safari writes and what CFNetwork
    /// matches against a Basic challenge.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrPort as String: port,
            kSecAttrProtocol as String: networkProtocol,
            kSecAttrSecurityDomain as String: Self.realm,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault
        ]
    }
}
