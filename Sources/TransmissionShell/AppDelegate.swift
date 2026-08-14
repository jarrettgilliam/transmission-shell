import AppKit
import TransmissionKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let notifier = Notifier()
    private let logger = Logger(subsystem: Bundle.transmissionShellIdentifier, category: "AppDelegate")

    private lazy var shellWindow: ShellWindowController = {
        let controller = ShellWindowController(model: model)
        controller.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        return controller
    }()

    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(model: model)
        controller.onSave = { [weak self] in
            self?.shellWindow.reload()
            self?.drainPending()
        }
        return controller
    }()

    /// URLs can arrive before `applicationDidFinishLaunching`, so they wait here until
    /// there's a config to add them against.
    private var pendingURLs: [URL] = []
    private var hasFinishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.load()

        // Anything already queued means a magnet or torrent file launched the app.
        let launchedByOpen = !pendingURLs.isEmpty
        hasFinishedLaunching = true

        if model.isConfigured {
            drainPending()
            shellWindow.present()
        } else {
            shellWindow.present()
            settingsWindow.present()
        }

        if launchedByOpen {
            logger.debug("Launched to handle \(self.pendingURLs.count) queued URL(s)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Staying resident is the point: later magnets shouldn't pay launch cost.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { shellWindow.present() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueue([URL(fileURLWithPath: filename)])
        return true
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.present()
    }

    @objc func reloadWebUI(_ sender: Any?) {
        shellWindow.reload()
    }

    private func enqueue(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        guard hasFinishedLaunching else { return }

        guard model.isConfigured else {
            settingsWindow.present()
            return
        }
        drainPending()
    }

    private func drainPending() {
        guard model.isConfigured, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()

        Task { await add(urls) }
    }

    /// Adds sequentially so notifications land in the order the files were handed over.
    private func add(_ urls: [URL]) async {
        guard let client = model.client else { return }

        for url in urls {
            do {
                let source = try TorrentSource.from(url: url)
                let result = try await client.add(source)
                notifier.report(result)
            } catch {
                logger.error("Add failed: \(error.localizedDescription, privacy: .public)")
                notifier.reportFailure(error, describing: description(of: url))
            }
        }

        // Never forces the window forward — a queue of magnets from a browser shouldn't
        // yank focus away from it.
        shellWindow.reloadIfVisible()
    }

    private func description(of url: URL) -> String {
        url.isFileURL ? url.lastPathComponent : "Magnet link"
    }
}
