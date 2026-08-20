import Foundation
import os

/// Talks to one Transmission daemon's RPC endpoint.
///
/// An actor because the cached session ID is shared mutable state: several magnets can
/// be handed to the app at once when a queue of links is clicked in a browser.
///
/// Changing the server settings or the password means building a new client; this one
/// reads the password once and caches it.
public actor RPCClient {
    public static let sessionIDHeader = "X-Transmission-Session-Id"

    private let config: ServerConfig
    private let credentials: any CredentialStore
    private let transport: any HTTPTransport
    private let logger = Logger(subsystem: InstallationIdentity.current, category: "RPCClient")

    /// Empty means the daemon answered without ever asking for a session ID; `nil` means
    /// we haven't looked yet.
    private var sessionID: String?
    private var handshake: Task<String, any Error>?
    private var cachedAuthorization: String??

    public init(
        config: ServerConfig,
        credentials: any CredentialStore,
        transport: (any HTTPTransport)? = nil
    ) {
        self.config = config
        self.credentials = credentials
        self.transport = transport
            ?? URLSessionTransport(bypassCertificateValidation: config.bypassCertificateValidation)
    }

    /// Round-trips `session-get`. Throws ``RPCError`` describing why the server is
    /// unusable; returns nothing on success.
    public func testConnection() async throws {
        let _: NoArguments = try await perform(method: "session-get", arguments: NoArguments())
    }

    /// Adds a magnet or `.torrent` file.
    ///
    /// A torrent the daemon already has comes back as ``AddResult/duplicate(_:)`` rather
    /// than an error.
    @discardableResult
    public func add(_ source: TorrentSource, options: AddOptions = AddOptions()) async throws -> AddResult {
        var arguments = TorrentAddArguments()
        switch source {
        case .magnet(let url):
            arguments.filename = url.absoluteString
        case .file(let data):
            arguments.metainfo = data.base64EncodedString()
        }
        arguments.paused = options.paused
        arguments.downloadDir = options.downloadDir

        let result: TorrentAddResult = try await perform(method: "torrent-add", arguments: arguments)
        if let torrent = result.torrentAdded {
            return .added(torrent)
        }
        if let torrent = result.torrentDuplicate {
            return .duplicate(torrent)
        }
        throw RPCError.invalidResponse
    }

    public func remove(ids: [Int], deleteLocalData: Bool = false) async throws {
        let arguments = TorrentRemoveArguments(ids: ids, deleteLocalData: deleteLocalData)
        let _: NoArguments = try await perform(method: "torrent-remove", arguments: arguments)
    }

    private func perform<Arguments: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        arguments: Arguments
    ) async throws -> Result {
        let body = try JSONEncoder().encode(RPCRequest(method: method, arguments: arguments))
        let sessionID = try await currentSessionID()
        let (data, response) = try await send(body: body, sessionID: sessionID)

        guard response.statusCode == 409 else {
            return try decode(data, response: response)
        }

        // The daemon rotated its session ID. The new one rides along on the 409 itself,
        // so this costs no extra round trip.
        guard let rotated = response.value(forHTTPHeaderField: Self.sessionIDHeader), !rotated.isEmpty else {
            throw RPCError.sessionHandshakeFailed
        }
        logger.debug("Session ID rotated; retrying \(method, privacy: .public)")
        self.sessionID = rotated

        let (retryData, retryResponse) = try await send(body: body, sessionID: rotated)
        guard retryResponse.statusCode != 409 else { throw RPCError.sessionHandshakeFailed }
        return try decode(retryData, response: retryResponse)
    }

    private func decode<Result: Decodable & Sendable>(_ data: Data, response: HTTPURLResponse) throws -> Result {
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw RPCError.unauthorized
        default:
            throw RPCError.httpError(status: response.statusCode)
        }

        let envelope: RPCResponse<Result>
        do {
            envelope = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
        } catch {
            logger.error("Undecodable response: \(error.localizedDescription, privacy: .public)")
            throw RPCError.invalidResponse
        }

        // A 200 says the request was well-formed, not that it worked.
        guard envelope.result == "success" else { throw RPCError.rpcFailure(envelope.result) }
        guard let arguments = envelope.arguments else { throw RPCError.invalidResponse }
        return arguments
    }

    private func send(body: Data, sessionID: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: config.rpcURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: Self.sessionIDHeader)
        }
        if let authorization = try authorizationHeader() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            return try await transport.send(request)
        } catch let error as RPCError {
            throw error
        } catch {
            throw RPCError.unreachable(error.localizedDescription)
        }
    }

    private func authorizationHeader() throws -> String? {
        if let cachedAuthorization { return cachedAuthorization }
        let credential = try credentials.credential()
        let header = config.authorizationHeader(username: credential?.username, password: credential?.password)
        cachedAuthorization = header
        return header
    }

    /// The daemon answers 409 to any request lacking a valid session ID, so the ID is
    /// established once with a throwaway `session-get` rather than by letting every
    /// queued add discover it the hard way. Concurrent callers share one handshake.
    private func currentSessionID() async throws -> String {
        if let sessionID { return sessionID }
        if let handshake { return try await handshake.value }

        let task = Task { try await self.fetchSessionID() }
        handshake = task
        do {
            let fetched = try await task.value
            sessionID = fetched
            handshake = nil
            return fetched
        } catch {
            handshake = nil
            throw error
        }
    }

    private func fetchSessionID() async throws -> String {
        let body = try JSONEncoder().encode(RPCRequest(method: "session-get", arguments: NoArguments()))
        let (_, response) = try await send(body: body, sessionID: "")

        switch response.statusCode {
        case 409:
            guard let id = response.value(forHTTPHeaderField: Self.sessionIDHeader), !id.isEmpty else {
                throw RPCError.sessionHandshakeFailed
            }
            return id
        case 200:
            return ""
        case 401, 403:
            throw RPCError.unauthorized
        default:
            throw RPCError.httpError(status: response.statusCode)
        }
    }
}
