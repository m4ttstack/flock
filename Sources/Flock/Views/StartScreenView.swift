import FlockCore
import SwiftUI

enum StartScreenLaunch {
    /// Opens a workspace in `folder`, then runs the choice in its first pane,
    /// as an empty pin does (`EmptyPinLaunch`).
    @MainActor
    static func start(
        with entry: HarnessEntry, via path: LauncherSlots.LaunchPath, in folder: String, on viewModel: SessionViewModel
    ) async {
        LauncherSlots.flash(entry, via: path, on: .startScreen, viewModel: viewModel)
        guard let pane = await viewModel.startWorkspace(in: folder) else { return }
        viewModel.recordLauncherKeystroke(pane)
        guard entry.id != ShellEntry.entry.id else { return }
        _ = await viewModel.awaitPrompt(pane)
        await LauncherSlots.launch(entry, in: pane, via: .click, on: viewModel)
    }
}

/// What the Workspaces view shows on a server with no workspaces: the
/// empty pin's launcher, and the folder the first workspace opens in.
/// Nothing opens until a choice is made.
struct StartScreenView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let folders: StartingFolderStore
    /// nil on the default server, which needs no naming.
    let serverName: String?
    var home = NSHomeDirectory()

    @FocusState private var isFocused: Bool
    @State private var isFolderHovered = false

    private var folder: String { folders.startScreenFolder(home: home) }

    var body: some View {
        VStack(spacing: ChromeMetrics.EmptyPin.sectionSpacing) {
            VStack(spacing: ChromeMetrics.EmptyPin.identitySpacing) {
                Text("No workspaces yet")
                    .font(ChromeType.emptyPinName)
                    .foregroundStyle(theme.textStrong)
                if let serverName {
                    Text("on \(serverName)")
                        .font(ChromeType.emptyPinCaption)
                        .foregroundStyle(theme.textLabel)
                        .accessibilityIdentifier("flock.startScreen.server")
                }
            }
            ViewThatFits(in: .horizontal) {
                launcher(showsShortcuts: true)
                launcher(showsShortcuts: false)
            }
            folderLine
        }
        .padding(.horizontal, ChromeMetrics.Launcher.hintHorizontalPadding)
        .padding(.bottom, ChromeMetrics.EmptyPin.lift * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.pane)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.return, phases: .down) { _ in
            launch(ShellEntry.entry, via: .key)
            return .handled
        }
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.startScreen")
    }

    private var folderLine: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text("in")
                    .font(ChromeType.emptyPinCaption)
                Text(Self.shortened(folder, home: home))
                    .font(ChromeType.emptyPinFolder)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(ChromeType.emptyPinCaption)
            .foregroundStyle(isFolderHovered ? theme.textStrong : theme.textLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isFolderHovered = $0 }
        .help("Choose the folder the first workspace opens in")
        .accessibilityIdentifier("flock.startScreen.folder")
    }

    private func launcher(showsShortcuts: Bool) -> some View {
        LauncherBar(
            style: LauncherBarStyle(theme: theme), slots: LauncherSlots.current(), showsShortcuts: showsShortcuts,
            flashedSlot: viewModel.flashedLauncherSlot(on: .startScreen),
            leading: (ShellEntry.entry, ShellEntry.shortcutLabel), onLaunch: { launch($0, via: .click) }
        )
    }

    static func shortened(_ folder: String, home: String) -> String {
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    private func chooseFolder() {
        guard let path = FolderPanel.choose(current: folder, message: "The first workspace opens in this folder.") else { return }
        folders.pickStartScreenFolder(path)
    }

    private func launch(_ entry: HarnessEntry, via path: LauncherSlots.LaunchPath) {
        let folder = folder
        Task { await StartScreenLaunch.start(with: entry, via: path, in: folder, on: viewModel) }
    }
}
