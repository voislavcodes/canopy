import AppKit

/// Custom NSWindow subclass that intercepts key events via sendEvent
/// for computer keyboard piano input. This is the most reliable
/// interception point — before the responder chain, before SwiftUI.
class CanopyWindow: NSWindow {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Bool)?

    private var customTitleLabel: NSTextField?

    /// Install a custom centered title label in the titlebar.
    /// Call after the window is on screen.
    func installCenteredTitle() {
        titleVisibility = .hidden

        guard let titlebarContainer = standardWindowButton(.closeButton)?.superview else { return }

        customTitleLabel?.removeFromSuperview()

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .windowFrameTextColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        titlebarContainer.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: titlebarContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: titlebarContainer.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: titlebarContainer.leadingAnchor, constant: 70),
            label.trailingAnchor.constraint(lessThanOrEqualTo: titlebarContainer.trailingAnchor, constant: -8),
        ])

        customTitleLabel = label
    }

    /// Update the centered title text.
    func updateCenteredTitle(_ newTitle: String) {
        title = newTitle
        customTitleLabel?.stringValue = newTitle
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if let handler = keyDownHandler, handler(event) {
                return // consumed
            }
        } else if event.type == .keyUp {
            if let handler = keyUpHandler, handler(event) {
                return // consumed
            }
        }
        super.sendEvent(event)
    }
}
