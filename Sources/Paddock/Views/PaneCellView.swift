import AppKit
import PaddockCore
import SwiftUI

/// A single pane cell: the title, status dot, and chip ride the top border
/// line as a legend (herdr's own pane framing), so no header row spends
/// terminal space; the body swaps between status-card mode (glyph/cwd/hint,
/// for a pane not yet attached) and live mode (its one ghostty surface) once
/// `SessionViewModel` hands one back. Every pane the canvas renders is a
/// visible pane of the selected tab, so it attaches on first visibility per
/// the standing attach policy; card mode is what shows while that attach is
/// still in flight.
struct PaneCellView: View {
    /// Half the legend's height: the framed box begins this far below the
    /// cell's top so the legend can sit centered on the box's top edge
    /// without leaving the cell's own frame.
    static let legendHalfHeight: CGFloat = 8
    /// Terminal content insets inside the box. Top clears the legend's lower
    /// half; the rest mirrors the artboards' text inset from the frame.
    static let contentInsets = EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10)
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

    @Environment(ToastCenter.self) private var toastCenter
    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @State private var ghosttySurface: (any GhosttyPaneSurface)?

    /// Seeds `ghosttySurface` from the pool synchronously, at construction --
    /// a warm (parked) pane's surface is already there, so it never renders
    /// the status card even for one frame while `.task(id:)` catches up. A
    /// cold pane's pool lookup is `nil`, same as the implicit default the
    /// synthesized init would have given it, so this changes nothing for
    /// that case.
    init(
        theme: Theme, viewModel: SessionViewModel, pane: PaneRecord, isFocused: Bool,
        lastLine: String?, cols: Int, rows: Int
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.pane = pane
        self.isFocused = isFocused
        self.lastLine = lastLine
        self.cols = cols
        self.rows = rows
        _ghosttySurface = State(initialValue: viewModel.ghosttySurface(for: pane.paneID))
    }

    /// `ToastCenter.current` narrowed to this pane; every other pane's cell
    /// narrows the same single slot to `nil`, so only the one pane a copy
    /// happened in ever shows the whisper.
    private var ownToast: ToastCenter.Toast? {
        guard let toast = toastCenter.current, toast.paneID == pane.paneID else { return nil }
        return toast
    }

    var body: some View {
        cell
    }

    private var cell: some View {
        box
            .padding(.top, Self.legendHalfHeight)
            .overlay(alignment: .topLeading) { legend }
            .overlay(alignment: .topTrailing) { statusChip }
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
    }

    /// Rows for both the card-mode SwiftUI `.contextMenu` and the ghostty
    /// branch's real `NSMenu` (`PaneMenuBuilder`) -- the same rows, so the
    /// two can never drift.
    private var paneMenuEntries: [PaneMenuEntry] {
        guard let model = viewModel.model else { return [] }
        return PaneMenuModel.entries(for: pane.paneID, model: model, focusedPane: viewModel.resolvedFocusedPaneID)
    }

    /// The framed terminal box. Content is clipped to the rounded frame and
    /// the focus halo is a real ring geometry (even-odd cutout) so no accent
    /// fill can bleed into the interior.
    private var box: some View {
        content
            .padding(Self.contentInsets)
            .background(theme.terminalGround)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isFocused ? theme.accent : theme.separator, lineWidth: isFocused ? 2 : 1)
            )
            .background {
                if isFocused {
                    HaloRing(cornerRadius: 9, thickness: 3)
                        .fill(theme.accent.opacity(0.18), style: FillStyle(eoFill: true))
                        .padding(-3)
                }
            }
    }

    /// Dot + title inlaid on the box's top edge. The two-tone backing paints
    /// the canvas ground above the edge and the terminal ground below it, so
    /// the border line reads as interrupted by the legend rather than as a
    /// pill floating over it.
    private var legend: some View {
        HStack(spacing: 6) {
            StatusDot(status: pane.agentStatus, theme: theme)
            Text(pane.terminalTitleStripped ?? pane.label ?? "shell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
        .legendBacking(above: theme.windowBg, below: theme.terminalGround, halfHeight: Self.legendHalfHeight)
        .padding(.leading, 12)
        .contentShape(Rectangle())
        // SwiftUI's tap gesture on macOS fires for the secondary button as
        // well, so the click is checked before it may act as a focus click;
        // the right-click falls through to the context menu below.
        .onTapGesture {
            guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
            Task { await viewModel.jumpToHerdr(pane: pane.paneID) }
        }
        .modifier(swiftUIPaneMenu)
        .accessibilityIdentifier("paddock.pane.legend.\(pane.paneID.rawValue)")
    }

    @ViewBuilder
    private var statusChip: some View {
        if let statusColor {
            Text(pane.agentStatus.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(statusColor.opacity(0.14)))
                .legendBacking(above: theme.windowBg, below: theme.terminalGround, halfHeight: Self.legendHalfHeight)
                .padding(.trailing, 12)
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

    /// `ghosttySurface` mounts as soon as it exists, whether or not its
    /// bridge has painted a first frame yet -- libghostty needs a real
    /// window to render into, so a cold attach's surface has to be in the
    /// hierarchy (opacity 0, under the card) from the start, not swapped in
    /// only once ready. `hasFirstFrame` then just crossfades which of the
    /// two is the one actually visible; a warm (pool-seeded) surface starts
    /// this already `true`, so its card never appears at all.
    @ViewBuilder
    private var content: some View {
        if let ghosttySurface {
            ZStack(alignment: .top) {
                GhosttyPaneTerminalView(
                    surface: ghosttySurface, theme: theme, isFocused: isFocused,
                    textSize: terminalTextSizeStore.active,
                    onPrimaryClick: { Task { await viewModel.jumpToHerdr(pane: pane.paneID) } },
                    menuProvider: { PaneMenuBuilder.menu(for: pane.paneID, viewModel: viewModel) }
                )
                .opacity(ghosttySurface.hasFirstFrame ? 1 : 0)
                if !ghosttySurface.hasFirstFrame {
                    cardContent
                        .transition(.opacity)
                }
                // Routed through `pane.send_input`, never `ghosttySurface
                // .typeText` straight into the PTY: a launcher click can
                // land on a pane that is NOT the resolved-focused one (split
                // right, click back into the original pane, then click the
                // overlay on the new pane), and that pane's bridge is in
                // observe mode -- typeText's bytes would silently vanish
                // into a PTY the bridge drops all stdin from. send_input is
                // focus-independent, the same route the pane's own regular
                // keystrokes never get to take once they land on an
                // observe-mode pane.
                if viewModel.isPristineLauncherPane(pane.paneID) {
                    PaneLauncherOverlay(theme: theme, entries: HarnessRoster.detected()) { entry in
                        Task { await viewModel.launchHarness(entry.binary, in: pane.paneID) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: ghosttySurface.hasFirstFrame)
            .overlay(alignment: .bottomTrailing) {
                if let ownToast {
                    PaneCopiedToastPill(theme: theme, toast: ownToast)
                        .id(ownToast.id)
                        .padding(10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ownToast)
        } else {
            cardContent
                .modifier(swiftUIPaneMenu)
        }
    }

    /// The SwiftUI rendering of the pane menu, for the parts of the cell
    /// that are not the ghostty NSView (the card and the legend). The
    /// ghostty body supplies the same rows as a real `NSMenu` through
    /// `PaneMenuBuilder`; SwiftUI's `.contextMenu` can never reach an
    /// AppKit subview's right-click.
    private var swiftUIPaneMenu: PaneMenuModifier<AnyView> {
        PaneMenuModifier(entries: paneMenuEntries) { entry in
            AnyView(paneMenuButton(entry))
        }
    }

    /// One leaf row (never a submenu parent) for the SwiftUI menu -- the
    /// ghostty branch's real `NSMenu` builds the equivalent row itself, in
    /// `PaneMenuBuilder`.
    private func paneMenuButton(_ entry: PaneMenuEntry) -> some View {
        Button(entry.label) {
            guard let action = entry.action else { return }
            Task { await action.perform(paneID: pane.paneID, on: viewModel) }
        }
        .disabled(!entry.enabled)
        .accessibilityIdentifier(entry.accessibilityIdentifier)
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

/// The pane menu as SwiftUI rows, applied wherever the cell is SwiftUI
/// rather than the ghostty NSView. Submenu parents render as `Menu`, leaves
/// through `leaf`.
private struct PaneMenuModifier<Leaf: View>: ViewModifier {
    let entries: [PaneMenuEntry]
    let leaf: (PaneMenuEntry) -> Leaf

    func body(content: Content) -> some View {
        content.contextMenu {
            ForEach(entries, id: \.accessibilityIdentifier) { entry in
                if let submenu = entry.submenu {
                    Menu(entry.label) {
                        ForEach(submenu, id: \.accessibilityIdentifier) { subEntry in
                            leaf(subEntry)
                        }
                    }
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                } else {
                    leaf(entry)
                }
            }
        }
    }
}

private extension NSEvent {
    static func isSecondaryButtonEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return true
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }
}

private extension View {
    /// Pins a legend element to a fixed row of `2 * halfHeight`, centered on
    /// the seam between the two grounds, and paints each ground on its side
    /// of that seam behind the element.
    func legendBacking(above: Color, below: Color, halfHeight: CGFloat) -> some View {
        padding(.horizontal, 5)
            .frame(height: halfHeight * 2)
            .background {
                VStack(spacing: 0) {
                    above
                    below
                }
            }
    }
}

/// The "Copied" whisper, geometry per the Interactions artboard's copy-on-
/// selection panel: 10pt inset from the pane's bottom-right corner, 10/5
/// padding, 6pt radius, 11pt icon, 10pt label.
private struct PaneCopiedToastPill: View {
    let theme: Theme
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.green)
            Text(toast.message)
                .font(.system(size: 10))
                .foregroundStyle(theme.chromeTextStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.paneHeaderBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.tabPillSelectedBorder, lineWidth: 1))
        .shadow(color: theme.railBg.opacity(0.4), radius: 9, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }
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
