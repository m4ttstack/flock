import AppKit

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
}
