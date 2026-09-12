import PaddockCore
import SwiftUI

/// A single pane cell: header (title/dot/chip) stays constant, the body
/// swaps between status-card mode (glyph/cwd/hint, for a pane not yet
/// attached) and live mode (a real terminal view) once `SessionViewModel`
/// hands back a feed. Every pane the canvas renders is a visible pane of the
/// selected tab, so it attaches live per the standing attach policy; card
/// mode is what shows while that attach is still in flight.
struct PaneCellView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneRecord
    let isFocused: Bool
    let lastLine: String?
    /// The pane's real terminal cell size, straight from the layout
    /// snapshot's `CellRect` -- never a pixel frame. Resizing this reattaches
    /// the live stream and resizes the terminal view in place.
    let cols: Int
    let rows: Int

    @State private var feed: PaneLiveFeed?
    /// Grabs system keyboard focus only while `isFocused`, so `onKeyPress`
    /// below only ever fires for the resolved-focused pane's own cell --
    /// "focused-pane only" is enforced by WHICH cell listens, not by a check
    /// inside `InputRouter` itself.
    @FocusState private var keyCaptureFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.terminalGround)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isFocused ? theme.accent : theme.separator, lineWidth: isFocused ? 2 : 1)
        )
        // A solid, unblurred halo ring outside the cell (matching the
        // reference's `box-shadow: 0 0 0 3px`, zero blur, fixed spread).
        // `HaloRing` is a real ring geometry (even-odd cutout), not a filled
        // rect relying on the opaque cell to hide its interior -- a filled
        // rect there visibly bled accent color across the header.
        .background {
            if isFocused {
                HaloRing(cornerRadius: 9, thickness: 3)
                    .fill(theme.accent.opacity(0.18), style: FillStyle(eoFill: true))
                    .padding(-3)
            }
        }
        .task(id: AttachDims(paneID: pane.paneID, cols: cols, rows: rows)) {
            if let newFeed = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: cols, rows: rows) {
                feed = newFeed
            }
        }
        .onDisappear {
            let paneID = pane.paneID
            Task { await viewModel.endLiveAttach(pane: paneID) }
        }
        .focusable(isFocused)
        .focusEffectDisabled()
        .focused($keyCaptureFocused)
        .onChange(of: isFocused, initial: true) { _, newValue in keyCaptureFocused = newValue }
        .onKeyPress(phases: .down) { press in
            guard isFocused else { return .ignored }
            return routeKeyPress(press)
        }
        .contextMenu {
            Button("Split Right") {
                Task { await viewModel.splitRight(from: pane.paneID) }
            }
            .accessibilityIdentifier("paddock.pane.menu.splitRight")
            Button("Split Down") {
                Task { await viewModel.splitDown(from: pane.paneID) }
            }
            .accessibilityIdentifier("paddock.pane.menu.splitDown")
            Divider()
            Button("Close Pane") {
                Task { await viewModel.closePane(pane.paneID) }
            }
            .accessibilityIdentifier("paddock.pane.menu.closePane")
            Divider()
            Toggle(
                "Send Right-Clicks to Pane",
                isOn: Binding(
                    get: { viewModel.isRightClickRoutedToPane(pane.paneID) },
                    set: { _ in Task { await viewModel.toggleRightClickRouting(for: pane.paneID) } }
                )
            )
            .accessibilityIdentifier("paddock.pane.menu.rightClickToPane")
        }
    }

    /// Translates one SwiftUI `KeyPress` into an `InputRouter` call. Command
    /// combos (copy, quit, ...) are left alone (`.ignored`) so the system
    /// keeps handling them normally; everything else -- plain characters,
    /// the named specials, and Control combos -- routes to `send_input`,
    /// never through SwiftTerm's own input path.
    private func routeKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        let router = viewModel.inputRouter(for: pane.paneID)

        if press.modifiers.contains(.control), press.key.character.isLetter {
            router.sendControlCombo(press.key.character)
            viewModel.recordLauncherKeystroke(pane.paneID)
            return .handled
        }

        switch press.key {
        case .return: router.sendKey(.enter)
        case .escape: router.sendKey(.esc)
        case .upArrow: router.sendKey(.up)
        case .downArrow: router.sendKey(.down)
        case .leftArrow: router.sendKey(.left)
        case .rightArrow: router.sendKey(.right)
        case .delete: router.sendKey(.backspace)
        case .tab: router.sendKey(.tab)
        default:
            guard !press.characters.isEmpty else { return .ignored }
            router.typeCharacter(press.characters)
        }
        viewModel.recordLauncherKeystroke(pane.paneID)
        return .handled
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(status: pane.agentStatus, theme: theme)
            Text(pane.terminalTitleStripped ?? pane.label ?? "shell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let statusColor {
                Text(pane.agentStatus.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(statusColor.opacity(0.14)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.paneHeaderBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    /// Status chips only accompany the active states (working/blocked/done);
    /// idle and unknown are dot-only per the pane-states reference.
    private var statusColor: Color? {
        switch pane.agentStatus {
        case .working: theme.yellow
        case .blocked: theme.red
        case .done: theme.teal
        case .idle, .unknown: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let feed {
            ZStack(alignment: .top) {
                PaneTerminalView(
                    cols: cols, rows: rows, feed: feed, terminalGround: theme.terminalGround,
                    terminalForeground: theme.terminalForeground,
                    onPlainClick: { Task { await viewModel.jumpToHerdr(pane: pane.paneID) } },
                    paneTerminal: viewModel.paneTerminal(for: pane, cols: cols, rows: rows),
                    onScreenActivity: { nonEmptyRowCount in
                        viewModel.recordLauncherScreenActivity(pane.paneID, nonEmptyRowCount: nonEmptyRowCount)
                    },
                    historyDim: theme.overlay0
                )
                if viewModel.isPristineLauncherPane(pane.paneID) {
                    PaneLauncherOverlay(theme: theme, entries: HarnessRoster.detected()) { entry in
                        Task { await viewModel.launchHarness(entry.binary, in: pane.paneID) }
                    }
                }
            }
        } else {
            cardContent
        }
    }

    /// Vertical anatomy per the reference (glyph, cwd, chip when present,
    /// hint), centered -- both explicitly, so a reader doesn't have to know
    /// that `.frame(maxWidth: .infinity)`'s default alignment happens to
    /// agree with what's wanted here. Shown only until the live attach
    /// resolves (see `content`).
    private var cardContent: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(theme.overlay0)
            Text(cwdTail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.subtext0)
            if let lastLine, !lastLine.isEmpty {
                Text(lastLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.overlay0)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(theme.terminalGround)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.separator, lineWidth: 1))
                    )
            }
            Text(hintText)
                .font(.system(size: 9))
                .foregroundStyle(theme.overlay0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(14)
    }

    private var hintText: String { "click to focus in herdr" }

    private var cwdTail: String {
        guard let last = pane.cwd.split(separator: "/").last else { return pane.cwd }
        return "~/\(last)"
    }
}

private struct AttachDims: Equatable {
    let paneID: PaneID
    let cols: Int
    let rows: Int
}

/// A ring shape (outer rounded rect minus an inset inner one, even-odd
/// filled) so the focused-pane halo is geometrically confined to its band --
/// no reliance on an opaque foreground to hide fill in the interior.
private struct HaloRing: Shape {
    var cornerRadius: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius + thickness)
        path.addPath(Path(roundedRect: rect.insetBy(dx: thickness, dy: thickness), cornerRadius: cornerRadius))
        return path
    }
}
