import Foundation

/// A torrent as the daemon identifies it after an add.
public struct TorrentRef: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let hashString: String
}

public enum AddResult: Sendable, Equatable {
    case added(TorrentRef)

    /// The daemon already had this torrent. A success, not a failure.
    case duplicate(TorrentRef)

    public var torrent: TorrentRef {
        switch self {
        case .added(let torrent), .duplicate(let torrent): torrent
        }
    }
}

/// Optional `torrent-add` arguments. Anything left `nil` is omitted from the request
/// entirely, leaving the daemon's own defaults in charge.
public struct AddOptions: Sendable, Equatable {
    public var paused: Bool?
    public var downloadDir: String?

    public init(paused: Bool? = nil, downloadDir: String? = nil) {
        self.paused = paused
        self.downloadDir = downloadDir
    }
}

public enum RPCError: Error, Equatable, LocalizedError {
    case unauthorized
    case httpError(status: Int)

    /// The daemon kept answering 409 without ever supplying a usable session ID.
    case sessionHandshakeFailed

    /// The daemon answered with a `result` other than `"success"`; the string is its own.
    case rpcFailure(String)

    case invalidResponse
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The server rejected the username or password."
        case .httpError(let status):
            "The server responded with HTTP \(status)."
        case .sessionHandshakeFailed:
            "Couldn’t establish a session with the server."
        case .rpcFailure(let message):
            message
        case .invalidResponse:
            "The server’s response wasn’t understood."
        case .unreachable(let message):
            "Couldn’t reach the server: \(message)"
        }
    }
}

struct RPCRequest<Arguments: Encodable & Sendable>: Encodable {
    let method: String
    let arguments: Arguments
    var tag = 1
}

struct RPCResponse<Arguments: Decodable & Sendable>: Decodable {
    let result: String
    let arguments: Arguments?
}

struct NoArguments: Codable, Sendable {}

struct TorrentAddArguments: Encodable, Sendable {
    var filename: String?
    var metainfo: String?
    var paused: Bool?
    var downloadDir: String?

    enum CodingKeys: String, CodingKey {
        case filename, metainfo, paused
        case downloadDir = "download-dir"
    }
}

struct TorrentAddResult: Decodable, Sendable {
    let torrentAdded: TorrentRef?
    let torrentDuplicate: TorrentRef?

    enum CodingKeys: String, CodingKey {
        case torrentAdded = "torrent-added"
        case torrentDuplicate = "torrent-duplicate"
    }
}

struct TorrentRemoveArguments: Encodable, Sendable {
    let ids: [Int]
    let deleteLocalData: Bool

    enum CodingKeys: String, CodingKey {
        case ids
        case deleteLocalData = "delete-local-data"
    }
}
