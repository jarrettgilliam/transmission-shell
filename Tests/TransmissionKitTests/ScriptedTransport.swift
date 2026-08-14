import Foundation
import Synchronization
import TransmissionKit

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    static func sessionChallenge(id: String) -> StubResponse {
        StubResponse(status: 409, headers: [RPCClient.sessionIDHeader: id])
    }

    static let success = StubResponse.json(#"{"result":"success","arguments":{}}"#)

    static func added(id: Int = 7, name: String = "Fixture", hash: String = "abc123") -> StubResponse {
        .json(#"{"result":"success","arguments":{"torrent-added":{"id":\#(id),"name":"\#(name)","hashString":"\#(hash)"}}}"#)
    }

    static func duplicate(id: Int = 7, name: String = "Fixture", hash: String = "abc123") -> StubResponse {
        .json(#"{"result":"success","arguments":{"torrent-duplicate":{"id":\#(id),"name":"\#(name)","hashString":"\#(hash)"}}}"#)
    }
}

/// Replays a fixed script of responses and records every request it was handed, so the
/// session handshake can be asserted on without a daemon.
final class ScriptedTransport: HTTPTransport {
    private struct State {
        var queued: [StubResponse]
        var recorded: [URLRequest] = []
    }

    private let state: Mutex<State>
    private let repeatsLast: Bool

    /// With `repeatsLast`, the final response is served indefinitely; otherwise running
    /// off the end of the script is a test failure.
    init(_ responses: [StubResponse], repeatsLast: Bool = false) {
        self.state = Mutex(State(queued: responses))
        self.repeatsLast = repeatsLast
    }

    var recorded: [URLRequest] {
        state.withLock(\.recorded)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let stub = try state.withLock { state -> StubResponse in
            state.recorded.append(request)
            if state.queued.count > 1 || !repeatsLast {
                guard !state.queued.isEmpty else { throw ScriptExhausted() }
                return state.queued.removeFirst()
            }
            return state.queued[0]
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return (stub.body, response)
    }

    struct ScriptExhausted: Error {}
}

extension URLRequest {
    var jsonBody: [String: Any] {
        (try? JSONSerialization.jsonObject(with: httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    var rpcMethod: String? {
        jsonBody["method"] as? String
    }

    var rpcArguments: [String: Any] {
        jsonBody["arguments"] as? [String: Any] ?? [:]
    }

    var sessionID: String? {
        value(forHTTPHeaderField: RPCClient.sessionIDHeader)
    }

    var authorization: String? {
        value(forHTTPHeaderField: "Authorization")
    }
}
