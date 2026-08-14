import Foundation

/// The seam that lets ``RPCClient`` be exercised without a daemon.
public protocol HTTPTransport: Sendable {
    /// Throws only for transport-level failures; any HTTP status, including 4xx, comes
    /// back as a normal result.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Setting `allowsInvalidCertificates` accepts any server certificate, for daemons
    /// behind a proxy using an internal CA.
    public init(timeout: TimeInterval = 15, allowsInvalidCertificates: Bool = false) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(
            configuration: configuration,
            delegate: allowsInvalidCertificates ? PermissiveTrustDelegate() : nil,
            delegateQueue: nil
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RPCError.invalidResponse }
        return (data, http)
    }
}

private final class PermissiveTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
