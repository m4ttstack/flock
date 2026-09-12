import PaddockCore
import SwiftUI

/// A single pane cell: header (title/dot/chip) stays constant, the body
/// swaps between status-card mode (glyph/cwd/hint, for a pane not yet
/// attached) and live mode (its one ghostty surface) once `SessionViewModel`
/// hands one back. Every pane the canvas renders is a visible pane of the
/// selected tab, so it attaches on first visibility per the standing attach
/// policy; card mode is what shows while that attach is still in flight.
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

    @State private var ghosttySurface: (any GhosttyPaneSurface)?

    var body: some View {
        cell
    }

    private var cell: some View {
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
        // One task per (pane, dims) identity, never keyed on focus: the pane
        // gets exactly one surface for its whole visible life, created here
        // on first visibility and resized in place on every later dims
        // change. SwiftUI's `.task(id:)` cancellation is cooperative, so a
        // superseded task body (a fast resize while an earlier attach for
        // this pane is still settling) is not actually stopped -- it keeps
        // running to completion, sharing this view's unsynchronized
        // `ghosttySurface` `@State` with whatever fresh task body replaced
        // it. `attachPane` is itself chained through the view model's own
        // `paneWork`, so a stale body's call always resolves against
        // whatever the fresher body already did, never clobbering it: both
        // ultimately read back the SAME (single) surface for this pane.
        .task(id: AttachDims(paneID: pane.paneID, cols: cols, rows: rows)) {
            ghosttySurface = await viewModel.attachPane(pane.paneID, cols: cols, rows: rows)
        }
        .onDisappear {
            Task { await viewModel.detachPane(pane.paneID) }
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
        if let ghosttySurface {
            ZStack(alignment: .top) {
                GhosttyPaneTerminalView(
                    surface: ghosttySurface, theme: theme, isFocused: isFocused,
                    isRightClickRoutedToPane: viewModel.isRightClickRoutedToPane(pane.paneID),
                    paneTerminal: viewModel.paneTerminal(for: pane, cols: cols, rows: rows),
                    historyDim: theme.overlay0
                )
                // Writes straight to the surface's PTY (via the session),
                // not `pane.send_input`/`InputRouter`: there is no herdr
                // attach in between for a ghostty pane to route through.
                if viewModel.isPristineLauncherPane(pane.paneID) {
                    PaneLauncherOverlay(theme: theme, entries: HarnessRoster.detected()) { entry in
                        ghosttySurface.typeText(entry.binary + "\n")
                        viewModel.recordLauncherKeystroke(pane.paneID)
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
