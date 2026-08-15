import AppKit
import SwiftUI

/// Titled "Server Connection" rather than "Settings" because the web UI below has its own
/// preferences screen for the daemon itself; the title is what tells them apart.
@MainActor
final class SettingsWindowController: NSWindowController {
    var onSave: (() -> Void)?

    private let model: AppModel

    init(model: AppModel) {
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Server Connection"
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        let form = SettingsFormState(config: model.config)
        let view = SettingsView(
            model: model,
            form: form,
            onSave: { [weak self] in
                self?.close()
                self?.onSave?()
            },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingView(rootView: view)
        window?.contentView = hosting
        window?.setContentSize(hosting.fittingSize)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // AppKit puts the shell window back on top one runloop turn from now, so ordering
        // front only sticks if it is also done after that.
        DispatchQueue.main.async { [weak self] in self?.window?.makeKeyAndOrderFront(nil) }
    }
}
