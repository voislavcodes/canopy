import AppKit

/// Custom NSWindow subclass that intercepts key events via sendEvent
/// for computer keyboard piano input. This is the most reliable
/// interception point — before the responder chain, before SwiftUI.
class CanopyWindow: NSWindow {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Bool)?

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
