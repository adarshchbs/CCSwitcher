import AppKit

/// Modal alerts. The app has no window of its own to attach a sheet to.
@MainActor
enum Prompts {
    static func confirmSwitch(to label: String, sessions: [LiveSession]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Switch to \(label)?"
        let list = sessions.prefix(10).map { "• PID \($0.pid)  \($0.detail)" }.joined(separator: "\n")
        let more = sessions.count > 10 ? "\n• and \(sessions.count - 10) more" : ""
        alert.informativeText = "Running Claude sessions may keep using the old account until restarted:\n\n\(list)\(more)"
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    static func askLabel(suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save current login"
        alert.informativeText = "Name this account:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return run(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirmRemove(_ label: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove \(label)?"
        alert.informativeText = "This deletes the saved login from the Keychain. The current Claude login isn't changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return run(alert) == .alertFirstButtonReturn
    }

    static func show(_ error: SwitchError) {
        let alert = NSAlert()
        if error.isBlocking {
            alert.alertStyle = .critical
            alert.messageText = "Your Claude login needs attention"
        } else {
            alert.alertStyle = .warning
            alert.messageText = "CCSwitcher"
        }
        alert.informativeText = error.message
        run(alert)
    }

    static func showUnexpected(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unexpected error"
        alert.informativeText = String(describing: error)
        run(alert)
    }

    static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        run(alert)
    }

    @discardableResult
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
