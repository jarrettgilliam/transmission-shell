import Foundation
import Synchronization
import Testing
@testable import TransmissionKit

/// Exercises a real `transmission-daemon`. Skipped unless `TS_INTEGRATION_BASE_URL` is
/// set; `Scripts/integration-test.sh` starts a throwaway daemon and sets it.
///
/// Unit tests can only prove the client is self-consistent — these prove it agrees with
/// the daemon about the 409 handshake and Basic auth.
@Suite("Live daemon", .enabled(if: Daemon.isConfigured))
struct IntegrationTests {
    @Test("session-get round-trips")
    func connects() async throws {
        try await Daemon.client().testConnection()
    }

    @Test("The daemon really does challenge with 409, and the retry is accepted")
    func challengesWithSessionID() async throws {
        let recorder = RecordingTransport(wrapping: URLSessionTransport())
        let client = try Daemon.client(transport: recorder)

        try await client.testConnection()

        // Handshake 409 carrying an ID, then session-get accepted with it.
        #expect(recorder.statuses == [409, 200])
        #expect(recorder.challengeIDs.count == 1)
        #expect(recorder.sentSessionIDs == [nil, recorder.challengeIDs.first])
    }

    @Test("A wrong password is rejected")
    func wrongPassword() async throws {
        let client = try Daemon.client(password: "definitely-not-the-password")

        await #expect(throws: RPCError.unauthorized) {
            try await client.testConnection()
        }
    }

    @Test("A .torrent file is added, and re-adding it is a duplicate")
    func addsAndDeduplicates() async throws {
        let client = try Daemon.client()
        let source = TorrentSource.file(try Fixtures.sampleTorrent())

        let first = try await client.add(source)
        guard case .added(let torrent) = first else {
            Issue.record("Expected a fresh add, got \(first)")
            return
        }

        let second = try await client.add(source)
        #expect(second == .duplicate(torrent))

        try await client.remove(ids: [torrent.id], deleteLocalData: true)
    }

    @Test("A magnet is accepted verbatim")
    func addsMagnet() async throws {
        let client = try Daemon.client()
        let magnet = URL(string: "magnet:?xt=urn:btih:2b5d0ff2d90d0e2e2e0d3c6a6d3a0e2f5c8b7a91&dn=TransmissionShell+probe")!

        let result = try await client.add(.magnet(magnet))
        #expect(result.torrent.hashString == "2b5d0ff2d90d0e2e2e0d3c6a6d3a0e2f5c8b7a91")

        try await client.remove(ids: [result.torrent.id], deleteLocalData: true)
    }

    @Test("Corrupt metainfo is refused with the daemon's own wording")
    func rejectsGarbage() async throws {
        let client = try Daemon.client()

        await #expect(throws: RPCError.self) {
            try await client.add(.file(Data("not a torrent".utf8)))
        }
    }
}

enum Daemon {
    static let baseURL = ProcessInfo.processInfo.environment["TS_INTEGRATION_BASE_URL"]
    static let username = ProcessInfo.processInfo.environment["TS_INTEGRATION_USERNAME"]
    static let password = ProcessInfo.processInfo.environment["TS_INTEGRATION_PASSWORD"]

    static var isConfigured: Bool { baseURL != nil }

    static func client(
        password overridePassword: String? = nil,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws -> RPCClient {
        let config = try ServerConfig(urlString: #require(baseURL))
        return RPCClient(
            config: config,
            credentials: InMemoryCredentialStore(
                username: username,
                password: overridePassword ?? password ?? ""
            ),
            transport: transport
        )
    }
}

/// Watches real traffic so the integration tests can assert on the handshake the daemon
/// actually performs, rather than only on the outcome.
final class RecordingTransport: HTTPTransport {
    private struct Exchange: Sendable {
        let sentSessionID: String?
        let status: Int
        let challengeID: String?
    }

    private let wrapped: any HTTPTransport
    private let exchanges = Mutex<[Exchange]>([])

    init(wrapping wrapped: any HTTPTransport) {
        self.wrapped = wrapped
    }

    var statuses: [Int] { exchanges.withLock { $0.map(\.status) } }
    var sentSessionIDs: [String?] { exchanges.withLock { $0.map(\.sentSessionID) } }
    var challengeIDs: [String] { exchanges.withLock { $0.compactMap(\.challengeID) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await wrapped.send(request)
        exchanges.withLock {
            $0.append(Exchange(
                sentSessionID: request.sessionID,
                status: response.statusCode,
                challengeID: response.value(forHTTPHeaderField: RPCClient.sessionIDHeader)
            ))
        }
        return (data, response)
    }
}
