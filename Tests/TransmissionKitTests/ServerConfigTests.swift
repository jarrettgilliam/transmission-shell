import Foundation
import Testing
@testable import TransmissionKit

@Suite("ServerConfig normalization")
struct ServerConfigNormalizationTests {
    @Test("Addresses normalize to a base URL", arguments: [
        ("nas.local:9091", "http://nas.local:9091/transmission/"),
        ("http://nas.local:9091", "http://nas.local:9091/transmission/"),
        ("http://nas.local:9091/", "http://nas.local:9091/transmission/"),
        ("http://nas.local:9091/transmission", "http://nas.local:9091/transmission/"),
        ("http://nas.local:9091/transmission/", "http://nas.local:9091/transmission/"),
        ("  http://nas.local:9091/transmission/  ", "http://nas.local:9091/transmission/"),
        ("HTTP://NAS.local:9091/transmission/", "http://nas.local:9091/transmission/"),
        ("https://seedbox.example.com", "https://seedbox.example.com/transmission/"),
        ("https://example.com/tr/", "https://example.com/tr/"),
        ("https://example.com/a/b/c", "https://example.com/a/b/c/"),
        ("http://user:pw@nas.local:9091/transmission/", "http://nas.local:9091/transmission/"),
        ("http://nas.local:9091/transmission/?x=1#y", "http://nas.local:9091/transmission/")
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerConfig(urlString: input).baseURL.absoluteString == expected)
    }

    @Test("A URL copied from the browser loses its web UI tail", arguments: [
        "http://nas.local:9091/transmission/web/",
        "http://nas.local:9091/transmission/web",
        "http://nas.local:9091/transmission/web/index.html",
        "http://nas.local:9091/transmission/rpc"
    ])
    func stripsEndpointComponents(input: String) throws {
        #expect(try ServerConfig(urlString: input).baseURL.absoluteString == "http://nas.local:9091/transmission/")
    }

    @Test("A missing port stays missing, meaning the scheme default")
    func portIsNotInvented() throws {
        #expect(try ServerConfig(urlString: "https://torrents.example.com").baseURL.port == nil)
        #expect(try ServerConfig(urlString: "http://nas.local:9091").baseURL.port == 9091)
    }

    @Test("Unusable addresses are rejected", arguments: [
        ("", ConfigError.empty),
        ("   ", ConfigError.empty),
        ("ftp://nas.local/transmission/", ConfigError.unsupportedScheme("ftp")),
        ("http://", ConfigError.missingHost),
        ("http:///transmission/", ConfigError.missingHost)
    ])
    func rejects(input: String, expected: ConfigError) throws {
        #expect(throws: expected) { try ServerConfig(urlString: input) }
    }
}

@Suite("ServerConfig derived URLs")
struct ServerConfigDerivedURLTests {
    @Test("Both endpoints hang off the base", arguments: [
        ("http://nas.local:9091/transmission/",
         "http://nas.local:9091/transmission/rpc",
         "http://nas.local:9091/transmission/web/"),
        ("nas.local",
         "http://nas.local/transmission/rpc",
         "http://nas.local/transmission/web/"),
        ("https://example.com/tr/",
         "https://example.com/tr/rpc",
         "https://example.com/tr/web/"),
        ("https://example.com:8443/a/b/",
         "https://example.com:8443/a/b/rpc",
         "https://example.com:8443/a/b/web/")
    ])
    func derives(base: String, rpc: String, web: String) throws {
        let config = try ServerConfig(urlString: base)
        #expect(config.rpcURL.absoluteString == rpc)
        #expect(config.webURL.absoluteString == web)
    }

    @Test("The default points at a local daemon")
    func defaults() throws {
        let config = try ServerConfig(urlString: ServerConfig.defaultURLString)
        #expect(config.rpcURL.absoluteString == "http://localhost:9091/transmission/rpc")
    }
}

@Suite("Config persistence")
struct ConfigPersistenceTests {
    @Test("A round trip preserves the config")
    func roundTrip() throws {
        let config = try ServerConfig(
            urlString: "https://example.com/tr/",
            username: "jarrett",
            allowsInvalidCertificates: true
        )
        let store = InMemoryServerConfigStore()
        try store.save(config)

        #expect(try store.load() == config)
    }

    @Test("Nothing is stored until something is saved")
    func emptyStore() throws {
        #expect(try InMemoryServerConfigStore().load() == nil)
    }

    @Test("Decoding renormalizes, so stored junk can't bypass the rules")
    func decodingNormalizes() throws {
        let stored = #"{"baseURL":"http://nas.local:9091/transmission/web/","allowsInvalidCertificates":false}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(stored.utf8))

        #expect(config.baseURL.absoluteString == "http://nas.local:9091/transmission/")
        #expect(config.username == nil)
    }

    @Test("The password never rides along with the config")
    func passwordIsNotEncoded() throws {
        let config = try ServerConfig(urlString: "http://nas.local:9091/", username: "jarrett")
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)

        #expect(!encoded.lowercased().contains("password"))
    }
}

@Suite("Credential storage")
struct CredentialStoreTests {
    @Test("A stored password comes back")
    func roundTrip() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.password() == nil)

        try store.setPassword("hunter2")
        #expect(try store.password() == "hunter2")
    }

    @Test("Clearing removes it")
    func clearing() throws {
        let store = InMemoryCredentialStore(password: "hunter2")
        try store.setPassword(nil)

        #expect(try store.password() == nil)
    }

    @Test("An empty username means no header even with a password")
    func headerRequiresUsername() throws {
        let config = try ServerConfig(urlString: "http://nas.local:9091/", username: "")
        #expect(config.authorizationHeader(password: "hunter2") == nil)
    }

    @Test("A username with no password still authenticates")
    func passwordlessUser() throws {
        let config = try ServerConfig(urlString: "http://nas.local:9091/", username: "jarrett")
        #expect(config.authorizationHeader(password: nil) == "Basic \(Data("jarrett:".utf8).base64EncodedString())")
    }
}

@Suite("TorrentSource")
struct TorrentSourceTests {
    @Test("Magnet URLs pass through")
    func magnet() throws {
        let url = URL(string: "magnet:?xt=urn:btih:abc")!
        #expect(try TorrentSource.from(url: url) == .magnet(url))
    }

    @Test("File URLs are read into memory")
    func file() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).torrent")
        let data = try Fixtures.sampleTorrent()
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TorrentSource.from(url: url) == .file(data))
    }

    @Test("Anything else is refused")
    func unsupported() throws {
        #expect(throws: TorrentSourceError.unsupportedScheme("https")) {
            try TorrentSource.from(url: URL(string: "https://example.com/x.torrent")!)
        }
    }
}
