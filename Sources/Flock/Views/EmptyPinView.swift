import FlockCore
import SwiftUI

/// The plain shell an empty pin can open to, offered first beside the
/// navigator and the harnesses. Return reaches it, not a number. Its ground
/// is near black, never a mid grey: the bar's hover fill is one, and a badge
/// that matches it vanishes into the item it sits in.
enum ShellEntry {
    static let entry = HarnessEntry(
        id: "shell", binary: "shell", displayName: "shell", monogram: ">_",
        monogramColor: Color(white: 0.08), monogramInk: Color(white: 0.94),
        monogramFont: ChromeType.launcherPromptMonogram
    )
    static let shortcutLabel = "\u{21A9}"
}

enum EmptyPinLaunch {
    /// Opens the pin, then runs the choice in its first pane. The shell needs
    /// nothing run; marking the pane typed into puts its own launcher away,
    /// since the person has already chosen.
    @MainActor
    static func start(
        _ pin: PinID, with entry: HarnessEntry, via path: LauncherSlots.LaunchPath, on viewModel: SessionViewModel
    ) async {
        LauncherSlots.flash(entry, via: path, on: .pin(pin), viewModel: viewModel)
        guard let pane = await viewModel.start(emptyPin: pin) else { return }
        if entry.id == ShellEntry.entry.id {
            viewModel.recordLauncherKeystroke(pane)
        } else {
            _ = await viewModel.awaitPrompt(pane)
            await LauncherSlots.launch(entry, in: pane, via: .click, on: viewModel)
        }
    }
}

/// What the Workspaces view shows for an empty pin in place of a strip and
/// panes: the pin's mark, name and folder over the new pane's launcher.
/// Nothing opens until a choice is made.
struct EmptyPinView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let pin: PinnedWorkspace

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: ChromeMetrics.EmptyPin.sectionSpacing) {
            VStack(spacing: ChromeMetrics.EmptyPin.identitySpacing) {
                WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.EmptyPin.mark, foreground: theme.textDim)
                Text(pin.name)
                    .font(ChromeType.emptyPinName)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                Text((pin.folder as NSString).abbreviatingWithTildeInPath)
                    .font(ChromeType.emptyPinFolder)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ViewThatFits(in: .horizontal) {
                launcher(showsShortcuts: true)
                launcher(showsShortcuts: false)
            }
            Text("Pinned \u{00B7} no tabs open")
                .font(ChromeType.emptyPinCaption)
                .foregroundStyle(theme.textLabel)
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
        .accessibilityIdentifier("flock.emptyPin.\(pin.id.rawValue)")
    }

    private func launcher(showsShortcuts: Bool) -> some View {
        LauncherBar(
            style: LauncherBarStyle(theme: theme), slots: LauncherSlots.current(), showsShortcuts: showsShortcuts,
            flashedSlot: viewModel.flashedLauncherSlot(on: .pin(pin.id)),
            leading: (ShellEntry.entry, ShellEntry.shortcutLabel), onLaunch: { launch($0, via: .click) }
        )
    }

    private func launch(_ entry: HarnessEntry, via path: LauncherSlots.LaunchPath) {
        Task { await EmptyPinLaunch.start(pin.id, with: entry, via: path, on: viewModel) }
    }
}
