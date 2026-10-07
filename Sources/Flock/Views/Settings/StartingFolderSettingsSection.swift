import AppKit
import FlockCore
import SwiftUI

/// Where each new workspace, tab and pane starts. Picking Custom Folder…
/// asks for the folder there and then; cancelling leaves the previous choice
/// standing, since the picker reads the store back rather than its own state.
struct StartingFolderSettingsSection: View {
    let store: StartingFolderStore

    var body: some View {
        Section("Starting Folder") {
            ForEach(NewTerminalKind.allCases, id: \.self) { kind in
                let choice = store.choice(for: kind)
                Picker(selection: Binding(get: { choice.folder }, set: { select($0, for: kind) })) {
                    ForEach(StartingFolder.allCases, id: \.self) { folder in
                        Text(folder.displayName).tag(folder)
                    }
                } label: {
                    Text(kind.displayName)
                    if let detail = Self.detail(for: choice) {
                        Text(detail)
                    }
                }
                .accessibilityIdentifier("flock.settings.startingFolder.\(kind.rawValue)")
                if choice.folder == .custom {
                    LabeledContent {
                        Button("Change…") { chooseFolder(for: kind) }
                            .accessibilityIdentifier("flock.settings.startingFolder.\(kind.rawValue).change")
                    } label: {
                        Text(Self.customFolderLabel(for: choice))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    static func detail(for choice: StartingFolderChoice) -> String? {
        choice.folder == .mainCheckout ? "Home outside a git repo" : nil
    }

    static func customFolderLabel(for choice: StartingFolderChoice) -> String {
        choice.customPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen"
    }

    private func select(_ folder: StartingFolder, for kind: NewTerminalKind) {
        guard folder == .custom else { return store.select(folder, for: kind) }
        chooseFolder(for: kind)
    }

    private func chooseFolder(for kind: NewTerminalKind) {
        guard let path = FolderPanel.choose(
            current: store.choice(for: kind).customPath, message: "\(kind.displayName) starts in this folder."
        ) else { return }
        store.selectCustom(path: path, for: kind)
    }
}
