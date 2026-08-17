import AppKit
import WebKit
import TransmissionKit
import UniformTypeIdentifiers
import os

/// Hosts the daemon's own web UI. Nothing is injected into the page — the window is a
/// frame around it, and torrents are added over RPC instead.
@MainActor
final class ShellWindowController: NSWindowController {
    var onOpenSettings: (() -> Void)?

    private static let blankPage = URL(string: "about:blank")!

    private let model: AppModel
    private let webView: WKWebView
    private let container = NSView()
    private var placeholder: PlaceholderView?
    private let logger = Logger(subsystem: InstallationIdentity.current, category: "ShellWindow")

    init(model: AppModel) {
        self.model = model

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Bundle.transmissionShellName
        window.setFrameAutosaveName("ShellWindow")
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isHidden = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        window.contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    func present() {
        let wasOnScreen = isVisible
        bringForward()
        // Skipped when it was already up: a Dock click on a window you're looking at
        // shouldn't throw away your place in the page.
        if !wasOnScreen { reload() }
    }

    func presentAfterAdd() {
        bringForward()
        reload()
    }

    private func bringForward() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func reload() {
        updateTitle()

        guard let config = model.config else {
            showUnconfigured()
            return
        }
        clearPlaceholder()
        webView.load(URLRequest(url: config.webURL))
    }

    private func updateTitle() {
        let name = Bundle.transmissionShellName
        window?.title = model.config.map { "\(name) — \($0.baseURL.absoluteString)" } ?? name
    }

    private func showUnconfigured() {
        showPlaceholder(
            title: "No server configured",
            message: "Point \(Bundle.transmissionShellName) at your Transmission daemon to see its web interface here.",
            actions: [PlaceholderView.Action(title: "Open Settings…") { [weak self] in self?.onOpenSettings?() }]
        )
    }

    private func showPlaceholder(title: String, message: String, actions: [PlaceholderView.Action]) {
        clearPlaceholder()

        let view = PlaceholderView(title: title, message: message, actions: actions)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        placeholder = view
        webView.isHidden = true
    }

    private func clearPlaceholder() {
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    private func showFailure(_ message: String) {
        showPlaceholder(
            title: "Can’t reach the server",
            message: message,
            actions: [
                PlaceholderView.Action(title: "Try Again") { [weak self] in self?.reload() },
                PlaceholderView.Action(title: "Settings…") { [weak self] in self?.onOpenSettings?() }
            ]
        )
    }
}

extension ShellWindowController: NSWindowDelegate {
    /// Closing has to stop the page, not just hide it: the web UI polls the daemon on its own
    /// timers, and the window outlives its own close.
    func windowWillClose(_ notification: Notification) {
        webView.load(URLRequest(url: Self.blankPage))
    }
}

extension ShellWindowController: WKNavigationDelegate {
    /// The `async` spelling of this delegate method does not register with WebKit: it
    /// treats the challenge as unhandled, performs default handling, and renders the
    /// server's 401 body. Keep the completion-handler form.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = respond(to: challenge)
        completionHandler(disposition, credential)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            // A nonzero failure count means this credential was already rejected for this
            // protection space; offering it again just loops. Counting challenges instead
            // would starve the page, which authenticates each subresource and RPC poll.
            guard challenge.previousFailureCount == 0, let credential = model.webCredential() else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, credential)

        case NSURLAuthenticationMethodServerTrust:
            // ATS is off for this app, but that doesn't bypass TLS trust evaluation.
            guard model.config?.allowsInvalidCertificates == true,
                  let trust = challenge.protectionSpace.serverTrust
            else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))

        default:
            return (.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearPlaceholder()
        // Revealing the web view only once real content has painted keeps the blank page —
        // which WebKit draws white — from flashing before a load lands.
        webView.isHidden = webView.url == Self.blankPage
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handle(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        handle(error)
    }

    private func handle(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        logger.error("Web UI navigation failed: \(nsError.localizedDescription, privacy: .public)")

        let message = nsError.code == NSURLErrorUserCancelledAuthentication
            ? "The server rejected the username or password. Check them in Settings."
            : nsError.localizedDescription
        showFailure(message)
    }
}

extension ShellWindowController: WKUIDelegate {
    /// Without this the web UI's "Open Torrent" button does nothing: WebKit routes every
    /// file input through here and drops the click when no `uiDelegate` is set.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window else { return nil }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let torrent = UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [torrent]
        }
        panel.allowsOtherFileTypes = true

        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.urls
    }
}
