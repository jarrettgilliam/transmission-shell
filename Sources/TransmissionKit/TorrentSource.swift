import Foundation

/// Something that can be handed to the daemon's `torrent-add`.
public enum TorrentSource: Sendable, Equatable {
    case magnet(URL)

    /// The raw bytes of a `.torrent` file.
    case file(Data)

    /// Classifies a URL delivered by LaunchServices.
    ///
    /// Reads the file into memory for `file:` URLs, so it throws whatever
    /// `Data(contentsOf:)` throws. Throws ``TorrentSourceError/unsupportedScheme(_:)``
    /// for anything that is neither `magnet:` nor `file:`.
    public static func from(url: URL) throws -> TorrentSource {
        switch url.scheme?.lowercased() {
        case "magnet":
            .magnet(url)
        case "file":
            .file(try Data(contentsOf: url))
        case let scheme:
            throw TorrentSourceError.unsupportedScheme(scheme ?? "")
        }
    }
}

public enum TorrentSourceError: Error, Equatable, LocalizedError {
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "Can't add “\(scheme)” links; only magnet links and .torrent files are supported."
        }
    }
}
