import AppKit

/// Stands in for the web view when there's nothing to show: no server configured, or the
/// daemon didn't answer. WebKit's own error page names a URL and nothing else, and the
/// likely causes here — wrong port, wrong subpath, rejected credentials, VPN down — are
/// already worded properly by `RPCError` and `ConfigError`.
final class PlaceholderView: NSView {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    private let stack = NSStackView()

    init(title: String, message: String, actions: [Action]) {
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 380

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(detail)

        if !actions.isEmpty {
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.spacing = 12
            for action in actions {
                buttons.addArrangedSubview(ActionButton(action: action))
            }
            stack.setCustomSpacing(20, after: detail)
            stack.addArrangedSubview(buttons)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ActionButton: NSButton {
    private let handler: () -> Void

    init(action: PlaceholderView.Action) {
        self.handler = action.handler
        super.init(frame: .zero)
        title = action.title
        bezelStyle = .rounded
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
