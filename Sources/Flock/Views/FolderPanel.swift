import AppKit
import FlockCore

enum FolderPanel {
    @MainActor
    static func choose(current: String?, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        if let current { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Finder shows this Mac's folders, so a herdr machine's folder is typed.
    @MainActor
    static func chooseOnMachine(current: String?, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "A full path on the machine, like /Users/you/code."
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = "/Users/you/code"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let folder = PinFolders.machineFolder(field.stringValue) { return folder }
            alert.informativeText = "That isn't a full path. It must start with /."
        }
        return nil
    }

    @MainActor
    static func choose(current: String?, message: String, onMachine: Bool) -> String? {
        onMachine ? chooseOnMachine(current: current, message: message) : choose(current: current, message: message)
    }
}
