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

    /// Everything a cell's box holds besides its surface, per axis: what the
    /// canvas subtracts from a box before deriving the whole-cell grid, so the
    /// chrome never eats a terminal cell. Must agree with `cell`/`box`'s own
    /// padding exactly. Whole points on both axes, which is what keeps the
    /// surface's origin on the device-pixel grid the box was snapped to.
    static let chrome = CGSize(
        width: contentInsets.leading + contentInsets.trailing,
        height: legendHalfHeight + contentInsets.top + contentInsets.bottom
    )

    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneRecord
    let isFocused: Bool
    let lastLine: String?
    /// The whole-cell grid this pane's own box holds: what the surface is laid
    /// out at and, through `SessionViewModel`, the size herdr is asked for. A
    /// later change reaches the surface through the view model's coalesced
    /// dims path, never through a reattach.
    let grid: PTYSize
    /// Exactly `grid.cols x grid.rows` cells: the surface's frame, top-left in
    /// the box's content area, any remainder left as ground.
    let surfaceSize: CGSize
    /// The Terminal Text size every pane shares.
    let fontSizePoints: Double

    @Environment(ToastCenter.self) private var toastCenter
    @Environment(RearrangeMode.self) private var rearrangeMode
    @Environment(DragCoordinator.self) private var drag
    @State private var ghosttySurface: (any GhosttyPaneSurface)?
    @State private var isHoveringWhileRearranging = false
    /// The terminal body's frame in the drag space: what turns the body's own
    /// top-left point (AppKit) into a drag-space one.
    @State private var bodyFrame: CGRect = .zero

    /// Seeds `ghosttySurface` from the pool synchronously, at construction --
    /// a warm (parked) pane's surface is already there, so it never renders
    /// the status card even for one frame while `.task(id:)` catches up. A
    /// cold pane's pool lookup is `nil`, same as the implicit default the
    /// synthesized init would have given it, so this changes nothing for
    /// that case.
    init(
        theme: Theme, viewModel: SessionViewModel, pane: PaneRecord, isFocused: Bool,
        lastLine: String?, grid: PTYSize, surfaceSize: CGSize, fontSizePoints: Double
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.pane = pane
        self.isFocused = isFocused
        self.lastLine = lastLine
        self.grid = grid
        self.surfaceSize = surfaceSize
        self.fontSizePoints = fontSizePoints
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
            // The origin stays put and fades while its ghost is out, so the
            // drop target is read against the layout the drag started from.
            .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
            .animation(.easeOut(duration: 0.12), value: drag.isDragging(pane: pane.paneID))
    }

    private var cell: some View {
        box
            .padding(.top, Self.legendHalfHeight)
            // Under the legend and the chip, so both keep their own gestures,
            // and strictly above the terminal surface, so this is the at-rest
            // handle without taking a single terminal row.
            .overlay(alignment: .top) { chromeGrabBand }
            .overlay(alignment: .topLeading) { legend }
            .overlay(alignment: .topTrailing) { statusChip }
            // While rearranging a drag starts from ANY point on the pane,
            // gutters and sub-cell remainder included, which no subview of the
            // cell covers. Arming this as well as the body's own AppKit path
            // cannot start two drags: both call `beginIfIdle` and
            // `DragGestureMachine` starts a drag from `.idle` only.
            .contentShape(Rectangle())
            .simultaneousGesture(paneDrag, including: rearrangeMode.active ? .all : .subviews)
        // One task per pane identity, never keyed on the grid or focus: the
        // pane gets exactly one surface for its whole visible life, created
        // here on first visibility with the grid of that moment. A later box
        // change reaches the surface through `setPaneBoxDims` below, so
        // nothing here ever restarts the attach. `attachPane` is chained
        // through the view model's own `paneWork`, so this body always reads
        // back the single surface for this pane whatever else was queued.
        .task(id: pane.paneID) {
            ghosttySurface = await viewModel.attachPane(pane.paneID, cols: grid.cols, rows: grid.rows)
        }
        // The box moved (a window resize, a split appearing, a divider drag):
        // the view model records it and coalesces the send.
        .onChange(of: grid) { _, new in
            viewModel.setPaneBoxDims(pane.paneID, cols: new.cols, rows: new.rows)
        }
        .onDisappear {
            Task { await viewModel.detachPane(pane.paneID) }
        }
    }

    // MARK: - Dragging this pane

    /// The pane's own laid-out size, which the ghost is a scaled copy of.
    /// Read from the canvas geometry the drag layer already holds; the body
    /// frame is the fallback before the canvas has published one.
    private var paneGhost: DragCoordinator.Ghost {
        DragCoordinator.Ghost(
            title: pane.terminalTitleStripped ?? pane.label ?? "shell",
            symbol: "macwindow",
            originSize: drag.canvas.paneFrames[pane.paneID]?.size ?? bodyFrame.size
        )
    }

    /// The at-rest drag handle: the cell's top chrome, which is the legend
    /// line plus the inset above the terminal surface. It is chrome the cell
    /// already spends, so the handle costs no terminal rows and the first
    /// terminal line stays selectable text.
    private var chromeGrabBand: some View {
        Color.clear
            .frame(height: PaneGrabRegion.topChromeHeight(
                legendHalfHeight: Self.legendHalfHeight, contentInsetTop: Self.contentInsets.top
            ))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(paneDrag)
    }

    /// Starts a pane drag and nothing else: `DragCoordinator` drives it from
    /// there, so this view being torn down mid-drag (a spring-load reveal
    /// swapping the canvas out) cannot strand the gesture.
    ///
    /// `startLocation` is the PRESS point, not the current one, which is what
    /// makes this arm agree with the AppKit path: both hand over where the
    /// press landed, so the ghost and the cancel spring-back are the same
    /// whichever of them got there first.
    private var paneDrag: some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(.pane(pane.paneID), ghost: paneGhost, at: value.startLocation)
            }
    }

    /// The AppKit half: the body reports the PRESS point in its own top-left
    /// space, and this is the single place that becomes a drag-space point.
    private func handleBodyDragBegan(_ point: CGPoint) {
        drag.beginIfIdle(
            .pane(pane.paneID), ghost: paneGhost,
            at: CGPoint(x: bodyFrame.minX + point.x, y: bodyFrame.minY + point.y)
        )
    }

    /// Rows for both the card-mode SwiftUI `.contextMenu` and the ghostty
    /// branch's real `NSMenu` (`PaneMenuBuilder`) -- the same rows, so the
    /// two can never drift.
    private var paneMenuEntries: [PaneMenuEntry] {
        guard let model = viewModel.model else { return [] }
        return PaneMenuModel.entries(for: pane.paneID, model: model, focusedPane: viewModel.resolvedFocusedPaneID)
    }

    /// The framed terminal box. The content is pinned to exactly the
    /// surface's cols x rows cells, top-left in the box's content area (the
    /// box itself fills the frame the canvas laid out, so the sub-cell
    /// remainder is plain ground). Content is clipped to the rounded frame
    /// and the focus halo is a real ring geometry (even-odd cutout) so no
    /// accent fill can bleed into the interior.
    private var box: some View {
        content
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Self.contentInsets)
            .background(theme.terminalGround)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            // The track spans the content area, so the two paddings are the
            // box's own (asymmetric) content insets: a symmetric one would
            // leave the thumb unable to reach the last row.
            .overlay(alignment: .trailing) {
                PaneScrollIndicator(theme: theme, scroll: pane.scroll)
                    .padding(.top, Self.contentInsets.top)
                    .padding(.bottom, Self.contentInsets.bottom)
                    .padding(.trailing, 3)
            }
            .overlay {
                if rearrangeMode.active {
                    rearrangePaint
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .background {
                if isFocused, !rearrangeMode.active {
                    HaloRing(cornerRadius: 9, thickness: 3)
                        .fill(theme.accent.opacity(0.18), style: FillStyle(eoFill: true))
                        .padding(-3)
                }
            }
            .scaleEffect(rearrangeMode.active && isHoveringWhileRearranging ? 1.02 : 1)
            .onHover { isHoveringWhileRearranging = $0 }
            .animation(.easeOut(duration: 0.12), value: rearrangeMode.active)
            .animation(.easeOut(duration: 0.12), value: isHoveringWhileRearranging)
    }

    private var borderColor: Color {
        rearrangeMode.active || isFocused ? theme.accent : theme.separator
    }

    private var borderWidth: CGFloat {
        rearrangeMode.active || isFocused ? 2 : 1
    }

    /// Rearrange mode's repaint, per the spec's "Grabbing a pane" bullet:
    /// terminal content dims under a scrim and a centered grip glyph appears.
    /// `allowsHitTesting(false)` so the scrim never steals the click a drag
    /// gesture needs from anywhere on the pane.
    private var rearrangePaint: some View {
        ZStack {
            theme.surfaceDim.opacity(0.62)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
        .allowsHitTesting(false)
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
        // The legend is a drag handle at rest as well as in rearrange mode;
        // simultaneous with the tap above, which the 4pt minimum keeps
        // distinct from it.
        .simultaneousGesture(paneDrag)
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
                // Decorative, so it yields its part of the chrome band to the
                // drag handle underneath it.
                .allowsHitTesting(false)
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
                    fontSizePoints: fontSizePoints, rearrangeActive: rearrangeMode.active,
                    onPrimaryClick: { Task { await viewModel.jumpToHerdr(pane: pane.paneID) } },
                    menuProvider: { PaneMenuBuilder.menu(for: pane.paneID, viewModel: viewModel) },
                    onBodyDragBegan: handleBodyDragBegan
                )
                .reportsDragFrame { bodyFrame = $0 }
                .opacity(ghosttySurface.hasFirstFrame ? 1 : 0)
                if !ghosttySurface.hasFirstFrame {
                    cardContent
                        .transition(.opacity)
                }
                // Routed through `pane.send_input`, never straight into the
                // PTY: a launcher click can land on a pane that is NOT the
                // resolved-focused one (split right, click back into the
                // original pane, then click the overlay on the new pane), and
                // only the focused pane holds AppKit key focus. send_input is
                // focus-independent.
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
                // The card is spacers and text over no background, so
                // without a shape the menu answers only where a glyph
                // actually landed.
                .contentShape(Rectangle())
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
