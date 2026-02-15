import AppKit

class CanopyApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            NSLog("[CanopyApp] NSApp.sendEvent keyDown: %@ keyCode=%d", event.charactersIgnoringModifiers ?? "nil", event.keyCode)
        }
        super.sendEvent(event)
    }
}

let app = CanopyApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
