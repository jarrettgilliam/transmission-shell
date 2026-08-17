import Foundation
import Testing
@testable import TransmissionKit

private let magnet = URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=Cosmos+Laundromat&tr=udp%3A%2F%2Ftracker.example%3A6969")!

private func makeClient(
    transport: ScriptedTransport,
    username: String? = nil,
    password: String = ""
) throws -> RPCClient {
    let config = try ServerConfig(urlString: "http://nas.local:9091/transmission/")
    let credentials = InMemoryCredentialStore(username: username, password: password)
    return RPCClient(config: config, credentials: credentials, transport: transport)
}

@Suite("Session handshake")
struct SessionHandshakeTests {
    @Test("A session ID is established before the first real request")
    func establishesSessionUpFront() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "SID-1"), .added()])
        let client = try makeClient(transport: transport)

        _ = try await client.add(.magnet(magnet))

        #expect(transport.recorded.count == 2)
        #expect(transport.recorded[0].rpcMethod == "session-get")
        #expect(transport.recorded[0].sessionID == nil)
        #expect(transport.recorded[1].rpcMethod == "torrent-add")
        #expect(transport.recorded[1].sessionID == "SID-1")
    }

    @Test("The established ID is reused, not refetched")
    func cachesSessionID() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "SID-1"), .added(), .duplicate()])
        let client = try makeClient(transport: transport)

        _ = try await client.add(.magnet(magnet))
        _ = try await client.add(.magnet(magnet))

        #expect(transport.recorded.count == 3)
        #expect(transport.recorded.filter { $0.rpcMethod == "session-get" }.count == 1)
        #expect(transport.recorded[2].sessionID == "SID-1")
    }

    @Test("A rotated ID triggers exactly one retry")
    func rotationRetriesOnce() async throws {
        let transport = ScriptedTransport([
            .sessionChallenge(id: "SID-1"),
            .sessionChallenge(id: "SID-2"),
            .added()
        ])
        let client = try makeClient(transport: transport)

        _ = try await client.add(.magnet(magnet))

        #expect(transport.recorded.count == 3)
        #expect(transport.recorded[1].sessionID == "SID-1")
        #expect(transport.recorded[2].sessionID == "SID-2")
        #expect(transport.recorded[2].rpcMethod == "torrent-add")
    }

    @Test("Relentless 409s fail instead of looping")
    func loopGuard() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "SID-1")], repeatsLast: true)
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.sessionHandshakeFailed) {
            try await client.add(.magnet(magnet))
        }
        // Probe, the add, one retry — and then it gives up.
        #expect(transport.recorded.count == 3)
    }

    @Test("A 409 carrying no session ID is fatal, not retried forever")
    func challengeWithoutHeader() async throws {
        let transport = ScriptedTransport([StubResponse(status: 409)], repeatsLast: true)
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.sessionHandshakeFailed) {
            try await client.add(.magnet(magnet))
        }
        #expect(transport.recorded.count == 1)
    }

    @Test("Concurrent adds share one handshake")
    func coalescesHandshake() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "SID-1"), .added()], repeatsLast: true)
        let client = try makeClient(transport: transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try? await client.add(.magnet(magnet)) }
            }
        }

        #expect(transport.recorded.filter { $0.rpcMethod == "session-get" }.count == 1)
        #expect(transport.recorded.filter { $0.rpcMethod == "torrent-add" }.count == 10)
    }

    @Test("A daemon that never challenges is fine")
    func noSessionIDRequired() async throws {
        let transport = ScriptedTransport([.success, .added()])
        let client = try makeClient(transport: transport)

        _ = try await client.add(.magnet(magnet))

        #expect(transport.recorded[1].sessionID == nil)
    }
}

@Suite("torrent-add envelope")
struct TorrentAddEnvelopeTests {
    private func addRequest(
        _ source: TorrentSource,
        options: AddOptions = AddOptions()
    ) async throws -> URLRequest {
        let transport = ScriptedTransport([.sessionChallenge(id: "SID-1"), .added()])
        let client = try makeClient(transport: transport)
        _ = try await client.add(source, options: options)
        return transport.recorded[1]
    }

    @Test("A magnet URI is passed through verbatim")
    func magnetVerbatim() async throws {
        let request = try await addRequest(.magnet(magnet))

        #expect(request.jsonBody["method"] as? String == "torrent-add")
        #expect(request.jsonBody["tag"] as? Int == 1)
        #expect(request.rpcArguments["filename"] as? String == magnet.absoluteString)
        #expect(request.rpcArguments["metainfo"] == nil)
    }

    @Test("A .torrent file is sent as unwrapped base64")
    func fileAsBase64() async throws {
        let data = try Fixtures.sampleTorrent()
        let request = try await addRequest(.file(data))

        let metainfo = try #require(request.rpcArguments["metainfo"] as? String)
        #expect(metainfo == data.base64EncodedString())
        #expect(!metainfo.contains("\n"))
        #expect(Data(base64Encoded: metainfo) == data)
        #expect(request.rpcArguments["filename"] == nil)
    }

    @Test("Unset options are omitted entirely")
    func optionsOmittedByDefault() async throws {
        let request = try await addRequest(.magnet(magnet))

        #expect(request.rpcArguments["paused"] == nil)
        #expect(request.rpcArguments["download-dir"] == nil)
        #expect(request.rpcArguments.count == 1)
    }

    @Test("Set options use the daemon's spelling")
    func optionsSent() async throws {
        let request = try await addRequest(
            .magnet(magnet),
            options: AddOptions(paused: true, downloadDir: "/mnt/tank/incoming")
        )

        #expect(request.rpcArguments["paused"] as? Bool == true)
        #expect(request.rpcArguments["download-dir"] as? String == "/mnt/tank/incoming")
    }
}

@Suite("Result classification")
struct ResultClassificationTests {
    @Test("A new torrent comes back added, with its identifiers")
    func added() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .added(id: 42, name: "Sintel", hash: "deadbeef")])
        let client = try makeClient(transport: transport)

        let result = try await client.add(.magnet(magnet))

        #expect(result == .added(TorrentRef(id: 42, name: "Sintel", hashString: "deadbeef")))
        #expect(result.torrent.id == 42)
    }

    @Test("An already-present torrent is a success, not an error")
    func duplicate() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .duplicate(id: 9, name: "Sintel", hash: "cafe")])
        let client = try makeClient(transport: transport)

        let result = try await client.add(.magnet(magnet))

        #expect(result == .duplicate(TorrentRef(id: 9, name: "Sintel", hashString: "cafe")))
    }

    @Test("HTTP 200 with a failure result is a failure")
    func resultStringChecked() async throws {
        let transport = ScriptedTransport([
            .sessionChallenge(id: "S"),
            .json(#"{"result":"invalid or corrupt torrent file"}"#)
        ])
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.rpcFailure("invalid or corrupt torrent file")) {
            try await client.add(.magnet(magnet))
        }
    }

    @Test("A success naming neither shape is not a silent no-op")
    func unknownSuccessShape() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .success])
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.invalidResponse) {
            try await client.add(.magnet(magnet))
        }
    }

    @Test("Unparseable bodies are reported, not crashed on")
    func garbageBody() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .json("<html>proxy error</html>")])
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.invalidResponse) {
            try await client.add(.magnet(magnet))
        }
    }

    @Test("Other statuses surface as-is", arguments: [500, 502, 404])
    func httpErrors(status: Int) async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), StubResponse(status: status)])
        let client = try makeClient(transport: transport)

        await #expect(throws: RPCError.httpError(status: status)) {
            try await client.add(.magnet(magnet))
        }
    }
}

@Suite("Authentication")
struct AuthenticationTests {
    @Test("No username means no Authorization header")
    func authDisabled() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .success])
        let client = try makeClient(transport: transport)

        try await client.testConnection()

        #expect(transport.recorded.allSatisfy { $0.authorization == nil })
    }

    @Test("A username produces a Basic header on every request")
    func basicAuth() async throws {
        let transport = ScriptedTransport([.sessionChallenge(id: "S"), .success])
        let client = try makeClient(transport: transport, username: "jarrett", password: "hunter2")

        try await client.testConnection()

        let expected = "Basic \(Data("jarrett:hunter2".utf8).base64EncodedString())"
        #expect(transport.recorded.allSatisfy { $0.authorization == expected })
    }

    @Test("A rejected credential is distinguishable from other failures", arguments: [401, 403])
    func rejected(status: Int) async throws {
        let transport = ScriptedTransport([StubResponse(status: status)], repeatsLast: true)
        let client = try makeClient(transport: transport, username: "jarrett", password: "wrong")

        await #expect(throws: RPCError.unauthorized) {
            try await client.testConnection()
        }
    }
}

enum Fixtures {
    static func sampleTorrent() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/sample", withExtension: "torrent"))
        return try Data(contentsOf: url)
    }
}
