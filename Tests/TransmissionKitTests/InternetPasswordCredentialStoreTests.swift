import Foundation
import Security
import Testing
@testable import TransmissionKit

@Suite("InternetPasswordCredentialStore identity")
struct InternetPasswordCredentialStoreIdentityTests {
    @Test("The protection space comes from the base URL", arguments: [
        ("https://seedbox.example.com/transmission/", "seedbox.example.com", 443, "htps"),
        ("http://nas.local/transmission/", "nas.local", 80, "http"),
        ("http://nas.local:9091/transmission/", "nas.local", 9091, "http"),
        ("https://example.com:8443/a/b/", "example.com", 8443, "htps")
    ])
    func derives(urlString: String, server: String, port: Int, networkProtocol: String) throws {
        let store = InternetPasswordCredentialStore(config: try ServerConfig(urlString: urlString))

        #expect(store.server == server)
        #expect(store.port == port)
        #expect(store.networkProtocol == networkProtocol)
    }

    /// The path is where the daemon lives, not who it is: a browser's item for the same host
    /// and port has to match.
    @Test("The path stays out of the identity")
    func pathIsNotPartOfIdentity() throws {
        let base = InternetPasswordCredentialStore(config: try ServerConfig(urlString: "http://nas.local:9091/"))
        let nested = InternetPasswordCredentialStore(config: try ServerConfig(urlString: "http://nas.local:9091/a/b/"))

        #expect(base.server == nested.server)
        #expect(base.port == nested.port)
        #expect(base.networkProtocol == nested.networkProtocol)
    }

    @Test("The realm is the daemon's hardcoded one")
    func realmIsFixed() {
        #expect(InternetPasswordCredentialStore.realm == "Transmission")
    }
}

@Suite("InternetPasswordCredentialStore selection")
struct InternetPasswordCredentialStoreSelectionTests {
    private func candidate(account: String, modified: Date?) -> [String: Any] {
        var item: [String: Any] = [kSecAttrAccount as String: account]
        if let modified { item[kSecAttrModificationDate as String] = modified }
        return item
    }

    private func account(_ item: [String: Any]?) -> String? {
        item?[kSecAttrAccount as String] as? String
    }

    @Test("Nothing to choose from")
    func empty() {
        #expect(InternetPasswordCredentialStore.select([]) == nil)
    }

    @Test("A lone candidate wins whatever its attributes")
    func single() {
        let items = [candidate(account: "jarrett", modified: nil)]
        #expect(account(InternetPasswordCredentialStore.select(items)) == "jarrett")
    }

    @Test("The most recently modified item wins")
    func newestWins() {
        let items = [
            candidate(account: "old", modified: Date(timeIntervalSince1970: 100)),
            candidate(account: "new", modified: Date(timeIntervalSince1970: 200)),
            candidate(account: "older", modified: Date(timeIntervalSince1970: 50))
        ]
        #expect(account(InternetPasswordCredentialStore.select(items)) == "new")
    }

    @Test("Equal timestamps break on the account, so the choice is deterministic")
    func tieBreaksOnAccount() {
        let sameInstant = Date(timeIntervalSince1970: 100)
        let items = [
            candidate(account: "zoe", modified: sameInstant),
            candidate(account: "alice", modified: sameInstant)
        ]
        #expect(account(InternetPasswordCredentialStore.select(items)) == "alice")
    }

    @Test("An item with no timestamp loses to one that has it")
    func undatedSortsLast() {
        let items = [
            candidate(account: "undated", modified: nil),
            candidate(account: "dated", modified: Date(timeIntervalSince1970: 1))
        ]
        #expect(account(InternetPasswordCredentialStore.select(items)) == "dated")
    }
}
