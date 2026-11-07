import AppKit
import FlockCore
import SwiftUI

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

    /// A machine's folders come from the machine; Finder only has this Mac's.
    @MainActor
    static func choose(current: String?, message: String, machine: MachineFolderPick?, completion: @escaping (String) -> Void) {
        if let machine {
            MachineFolderPanel.choose(current: current, message: message, pick: machine) { folder in
                if let folder { completion(folder) }
            }
        } else if let folder = choose(current: current, message: message) {
            completion(folder)
        }
    }
}

extension EnvironmentValues {
    /// Set on a herdr machine's window only.
    @Entry var machineFolderLister: MachineFolderLister?
}

extension MachineFolderPick {
    @MainActor
    init?(lister: MachineFolderLister?, viewModel: SessionViewModel, theme: Theme?) {
        guard viewModel.isRemoteMachine, let lister, let theme else { return nil }
        self.init(lister: lister, suggestions: MachineFolderSuggestions.from(viewModel.model), theme: theme)
    }
}
