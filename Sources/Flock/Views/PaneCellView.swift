import AppKit
import FlockCore
import SwiftUI

/// The rearrange-mode hover lift: a shadow cast behind the pane's own box,
/// and nothing else.
///
/// It may not be a transform. A cell's laid-out frame is the same rect
/// `CanvasGeometry` publishes for drop hit-testing, so a scale would draw the
/// pane somewhere the drop resolver never looks and the pointer would land
/// against a box the user cannot see. A transform over the cell also pulls the
/// pane's AppKit terminal surface through an offscreen pass, which a
/// Metal-backed surface does not survive intact.
struct PaneHoverLift: ViewModifier {
    /// Behind `content`, so the shadow falls outside the box's own clip while
    /// the caster itself stays hidden under an opaque pane.
    let fill: Color
    let active: Bool

    static let shadowRadius: CGFloat = 16
    static let shadowOpacity: Double = 0.5
    static let shadowOffset: CGFloat = 5

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                .fill(fill)
                .shadow(
                    color: .black.opacity(active ? Self.shadowOpacity : 0),
                    radius: active ? Self.shadowRadius : 0,
                    y: active ? Self.shadowOffset : 0
                )
        }
    }
}

/// A single pane cell: a bordered box with the pane's title in its top
/// chrome, over a body that swaps between status-card mode (glyph/cwd/hint,
/// for a pane not yet attached) and live mode (its one ghostty surface) once
/// `SessionViewModel` hands one back. Every pane the canvas renders is a
/// visible pane of the selected tab, so it attaches on first visibility per
/// the standing attach policy; card mode is what shows while that attach is
/// still in flight.
struct PaneCellView: View {
    /// What the canvas subtracts from a box before deriving the whole-cell
    /// grid, so the chrome never eats a terminal cell. Must agree with
    /// `contentInsets` exactly.
    static let chrome = PaneChrome.size

    private static let contentInsets = EdgeInsets(
        top: PaneChrome.contentTop, leading: PaneChrome.horizontalPadding,
        bottom: PaneChrome.verticalPadding, trailing: PaneChrome.horizontalPadding
    )

    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneRecord
    let isFocused: Bool
    /// This pane is the one herdr's zoom is holding open on its tab, so it is
    /// filling the canvas alone (`CanvasComposition`). The badge is what says
    /// the tab still has other panes behind this one.
    let isZoomed: Bool
    let lastLine: String?
    /// The whole-cell grid this pane's own box holds, which `surfaceSize`
    /// lays the surface out at. herdr hears it only through the PTY.
    let grid: PTYSize
    /// Exactly `grid.cols x grid.rows` cells: the surface's frame, top-left in
    /// the box's content area, any remainder left as ground.
    let surfaceSize: CGSize
    /// The Terminal Text size every pane shares.
    let fontSizePoints: Double

    @Environment(ToastCenter.self) private var toastCenter
    @Environment(RearrangeMode.self) private var rearrangeMode
    @Environment(DragCoordinator.self) private var drag
    @Environment(ChatStore.self) private var chatStore
    @Environment(OptionAsAltStore.self) private var optionAsAltStore
    @State private var ghosttySurface: (any GhosttyPaneSurface)?
    @State private var isHoveringWhileRearranging = false
    @State private var isChatPopoverPresented = false
    /// Read once by `chatPopover`'s own `initialFeature`: nil for an
    /// ordinary click (always the status root), set only by the Chat menu's
    /// `onChange` below, and cleared alongside every open so a later plain
    /// click never inherits a stale route from an earlier shortcut.
    @State private var pendingPopoverFeature: ChatPopoverFeature?
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
        theme: Theme, viewModel: SessionViewModel, pane: PaneRecord, isFocused: Bool, isZoomed: Bool,
        lastLine: String?, grid: PTYSize, surfaceSize: CGSize, fontSizePoints: Double
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.pane = pane
        self.isFocused = isFocused
        self.isZoomed = isZoomed
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
        // Read here, unconditionally, and not only where it is used: the two
        // places below that consult an editor both sit behind a `&&` or a
        // ternary that Swift can skip, and a body that skips the read is a
        // body the editor's own opening never invalidates. That is what
        // decides whether this cell's surface hears about an editor at all
        // (`editorIsOpen`), and whether it takes the keyboard back when one
        // closes.
        //
        // On SCREEN, not merely open: a target outlives its view whenever
        // herdr's focus moves to another workspace or tab, and yielding to a
        // view nobody draws would leave the keyboard with nobody at all.
        let editorIsOpen = viewModel.renameEditorIsOnScreen
        return cell(editorIsOpen: editorIsOpen)
            // The origin stays put and fades while its ghost is out, so the
            // drop target is read against the layout the drag started from.
            .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
            .animation(.easeOut(duration: 0.12), value: drag.isDragging(pane: pane.paneID))
            // The Chat menu's own route into a specific pane's popover,
            // mirroring how a rename shortcut opens the rename editor rather
            // than a local click: consumed once so requesting this same
            // pane again later still reads as a change. The requested
            // feature rides along to `chatPopover`'s own `initialFeature`,
            // so a shortcut lands on the view it names rather than the root.
            .onChange(of: chatStore.requestedPopover) { _, requested in
                guard requested?.pane == pane.paneID else { return }
                pendingPopoverFeature = requested?.feature
                isChatPopoverPresented = true
                chatStore.clearPopoverRequest()
            }
    }

    private func cell(editorIsOpen: Bool) -> some View {
        box(editorIsOpen: editorIsOpen)
            // Under the title and the chip, so both keep their own gestures,
            // and strictly above the terminal surface, so this is the at-rest
            // handle without taking a single terminal row.
            .overlay(alignment: .top) { chromeGrabBand }
            .overlay(alignment: .topLeading) { title }
            .overlay(alignment: .topTrailing) { statusChip }
            // While rearranging a drag starts from ANY point on the pane,
            // gutters and sub-cell remainder included, which no subview of the
            // cell covers. Arming this as well as the body's own AppKit path
            // cannot start two drags: both call `beginIfIdle` and
            // `DragGestureMachine` starts a drag from `.idle` only.
            .contentShape(Rectangle())
            .simultaneousGesture(paneDrag, including: rearrangeMode.active && !isRenaming ? .all : .subviews)
        // One task per pane identity, never keyed on the grid or focus: the
        // pane gets exactly one surface for its whole visible life, created
        // here on first visibility. Every box change resizes the surface
        // through its frame, so nothing here ever restarts the attach.
        // `attachPane` is chained through the view model's own `paneWork`, so
        // this body always reads back the single surface for this pane
        // whatever else was queued.
        .task(id: pane.paneID) {
            ghosttySurface = await viewModel.attachPane(pane.paneID)
        }
        // Keyed on availability rather than the pane: this cancels and
        // restarts the moment `isAvailable` flips from false to true, which
        // is the ONLY other time this pane's status can newly become
        // fetchable. The guard is what keeps a machine without chat from
        // spawning anything on every launch (`isAvailable` starts false, so
        // the very first run of this task is a no-op there).
        .task(id: chatStore.isAvailable) {
            guard chatStore.isAvailable else { return }
            await chatStore.refreshStatus(for: pane.paneID)
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

    /// The at-rest drag handle: the box's top chrome above the terminal
    /// surface. It is chrome the box already spends, so the handle costs no
    /// terminal rows and the first terminal line stays selectable text.
    private var chromeGrabBand: some View {
        Color.clear
            .frame(height: PaneChrome.contentTop)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(paneDrag, including: isRenaming ? .subviews : .all)
            .onHover { hovering in
                // A pane drag already owns the cursor for its whole
                // duration (`DragCoordinator`'s own push); this band's own
                // exit -- the pointer leaving toward wherever the drag is
                // going -- must not repaint the closed hand away.
                guard !drag.isPaneDragInFlight else { return }
                (hovering ? NSCursor.openHand : NSCursor.arrow).set()
            }
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

    /// The bordered terminal box. The content is pinned to exactly the
    /// surface's cols x rows cells, top-left in the box's content area (the
    /// box itself fills the frame the canvas laid out, so the sub-cell
    /// remainder is plain ground).
    private func box(editorIsOpen: Bool) -> some View {
        content(editorIsOpen: editorIsOpen)
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Self.contentInsets)
            .background(theme.pane)
            .clipShape(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
            // The track spans the content area, so the two paddings are the
            // box's own (asymmetric) content insets: a symmetric one would
            // leave the thumb unable to reach the last row.
            .overlay(alignment: .trailing) {
                PaneScrollIndicator(theme: theme, scroll: pane.scroll)
                    .padding(.top, Self.contentInsets.top)
                    .padding(.bottom, Self.contentInsets.bottom)
                    .padding(.trailing, ChromeMetrics.Pane.scrollIndicatorInset)
            }
            .overlay {
                if rearrangeMode.active {
                    rearrangePaint
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .modifier(PaneHoverLift(fill: theme.pane, active: rearrangeMode.active && isHoveringWhileRearranging))
            .onHover { isHoveringWhileRearranging = $0 }
            .animation(.easeOut(duration: 0.12), value: rearrangeMode.active)
            .animation(.easeOut(duration: 0.12), value: isHoveringWhileRearranging)
    }

    private var borderColor: Color {
        rearrangeMode.active || isFocused ? theme.accent : theme.paneBorder
    }

    /// Rearrange mode's repaint, per the spec's "Grabbing a pane" bullet:
    /// terminal content dims under a scrim and a centered grip glyph appears.
    /// `allowsHitTesting(false)` so the scrim never steals the click a drag
    /// gesture needs from anywhere on the pane.
    private var rearrangePaint: some View {
        ZStack {
            theme.accent.opacity(DragVisuals.rearrangeScrimOpacity)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(ChromeType.rearrangeSymbol)
                .foregroundStyle(theme.accent)
        }
        .allowsHitTesting(false)
    }

    /// Whether the one rename editor is open on THIS pane.
    private var isRenaming: Bool {
        viewModel.renameTarget == .pane(pane.paneID)
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            InlineRenameField(
                theme: theme, font: ChromeType.paneTitle,
                initialText: viewModel.renameText(for: .pane(pane.paneID)),
                accessibilityIdentifier: "flock.pane.rename.\(pane.paneID.rawValue)",
                onCommit: { text in Task { await viewModel.commitRename(text, for: .pane(pane.paneID)) } },
                onCancel: { viewModel.cancelRename() }
            )
            .frame(width: ChromeMetrics.Rename.paneWidth, height: PaneChrome.titleRowHeight)
            .padding(.top, PaneChrome.verticalPadding)
            .padding(.leading, PaneChrome.horizontalPadding)
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        Text(pane.terminalTitleStripped ?? pane.label ?? "shell")
            .font(ChromeType.paneTitle)
            .foregroundStyle(isFocused ? theme.textStrong : theme.textDim)
            .lineLimit(1)
            .frame(height: PaneChrome.titleRowHeight)
            .padding(.top, PaneChrome.verticalPadding)
            .padding(.leading, PaneChrome.horizontalPadding)
            .contentShape(Rectangle())
        // ONE tap gesture, which is what keeps a plain click instant: a
        // `count: 2` sibling for the rename would make this one wait out the
        // system's double-click interval before it could fire at all
        // (`ChromeRowClick`). A right-click reads as `.ignore` and falls
        // through to the context menu below.
        .onTapGesture { handleTitleClick() }
        // The title is a drag handle at rest as well as in rearrange mode;
        // simultaneous with the tap above, which the 4pt minimum keeps
        // distinct from it.
        .simultaneousGesture(paneDrag)
        .modifier(swiftUIPaneMenu)
        .accessibilityIdentifier("flock.pane.title.\(pane.paneID.rawValue)")
    }

    /// Focus on the first click, the rename editor on the second. A title the
    /// user double-clicks is therefore focused on the way into the editor,
    /// which is the price of never holding a plain click back to find out
    /// whether a second one is coming.
    private func handleTitleClick() {
        switch NSEvent.chromeRowClick(NSApp.currentEvent) {
        case .select:
            Task { await viewModel.jumpToHerdr(pane: pane.paneID) }
        case .beginRename:
            viewModel.beginRename(.pane(pane.paneID))
        case .ignore:
            break
        }
    }

    /// The legend's trailing end: the zoom badge, then the status chip. The
    /// chat button is the one live control here, so hit testing is turned off
    /// on the zoom badge and the status pill themselves -- never on a
    /// container around all three -- since a disabled ancestor cannot be
    /// re-enabled from below it.
    private var statusChip: some View {
        HStack(spacing: ChromeMetrics.Pane.legendItemGap) {
            if isZoomed { zoomBadge.allowsHitTesting(false) }
            if chatButtonAppearance != .absent { chatButton }
            if let statusColor {
                Text(pane.agentStatus.rawValue)
                    .font(ChromeType.statusChip)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, ChromeMetrics.Pane.statusChipPadding)
                    .frame(height: PaneChrome.titleRowHeight)
                    .background(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).fill(statusColor.opacity(0.14)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, PaneChrome.verticalPadding)
        .padding(.trailing, PaneChrome.horizontalPadding)
    }

    private var chatButtonAppearance: ChatButtonModel.Appearance {
        ChatButtonModel.appearance(
            availability: chatStore.isAvailable, status: chatStore.status(for: pane.paneID),
            unread: chatStore.unreadCount(for: pane.paneID)
        )
    }

    /// One `.popover` wrapping the whole switch below, never one per branch:
    /// signing in flips `chatButtonAppearance` from `.signedOut` to
    /// `.signedIn`, and a modifier attached inside a branch is torn down and
    /// re-presented along with it, resetting the popover's own route.
    /// Wrapping the switch as a whole keeps the popover's host stable across
    /// that flip, since the conditional content's outer type does not change
    /// with which branch is live.
    private var chatButton: some View {
        chatButtonContent
            .popover(isPresented: $isChatPopoverPresented, arrowEdge: .bottom) { chatPopover }
    }

    @ViewBuilder
    private var chatButtonContent: some View {
        switch chatButtonAppearance {
        case .absent:
            EmptyView()
        case .signedOut:
            Button(action: { openChatPopover() }) {
                chatGlyph(color: theme.overlay0)
                    .frame(width: ChromeMetrics.ChatButton.iconSize.width, height: ChromeMetrics.ChatButton.iconSize.height)
                    .frame(width: ChromeMetrics.ChatButton.signedOutSize.width, height: ChromeMetrics.ChatButton.signedOutSize.height)
                    .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatButton.cornerRadius).fill(Color(theme.palette.surface0)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chat")
            .accessibilityIdentifier("flock.pane.chatButton.\(pane.paneID.rawValue)")
        case let .signedIn(handle, unread):
            Button(action: { openChatPopover() }) {
                HStack(spacing: ChromeMetrics.ChatButton.gap) {
                    Text(handle)
                        .font(ChromeType.chatButtonHandle)
                        .foregroundStyle(theme.green)
                        .lineLimit(1)
                        .frame(width: ChromeMetrics.ChatButton.handleSize.width, height: ChromeMetrics.ChatButton.handleSize.height, alignment: .leading)
                    chatGlyph(color: theme.green)
                        .frame(width: ChromeMetrics.ChatButton.iconSize.width, height: ChromeMetrics.ChatButton.iconSize.height)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(ChromeType.chatButtonHandle)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .frame(width: ChromeMetrics.ChatButton.countSize.width, height: ChromeMetrics.ChatButton.countSize.height, alignment: .leading)
                    }
                }
                .padding(.vertical, ChromeMetrics.ChatButton.verticalPadding)
                .padding(.horizontal, ChromeMetrics.ChatButton.horizontalPadding)
                .frame(height: ChromeMetrics.ChatButton.signedInHeight)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.ChatButton.cornerRadius).fill(Color(theme.palette.selectionBg))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(unread > 0 ? "Chat: \(handle), \(unread) unread" : "Chat: \(handle)")
            .accessibilityIdentifier("flock.pane.chatButton.\(pane.paneID.rawValue)")
        }
    }

    private var chatPopover: some View {
        ChatPopover(
            theme: theme, paneName: pane.terminalTitleStripped ?? pane.label ?? "shell",
            status: chatStore.status(for: pane.paneID), statusError: chatStore.statusError(for: pane.paneID),
            isPresented: $isChatPopoverPresented,
            onSignIn: { Task { await chatStore.signIn(pane.paneID) } },
            onSignOut: { Task { await chatStore.signOut(pane.paneID) } },
            onOpenViewer: { openChatViewer() },
            viewerDisabledReason: chatStore.viewerDisabledReason,
            onRetry: { Task { await chatStore.refreshStatus(for: pane.paneID) } },
            initialFeature: pendingPopoverFeature,
            onJump: { paneID in Task { await viewModel.focusFromChat(pane: paneID) } }
        )
        // A fresh fetch on every open, on top of the launch/availability
        // fetch above: a popover left closed for a while must not show a
        // status stale enough to contradict a Retry the user is about to
        // read as current.
        .task { await chatStore.refreshStatus(for: pane.paneID) }
    }

    /// Always the status root: only the Chat menu's `onChange` above sets
    /// `pendingPopoverFeature`, so a plain click never inherits a stale one
    /// left over from an earlier shortcut.
    private func openChatPopover() {
        pendingPopoverFeature = nil
        isChatPopoverPresented = true
    }

    /// Fire-and-forget: the store's own toast covers a failed call, and
    /// there is nothing else here for a viewer URL to report back to.
    private func openChatViewer() {
        Task {
            guard let url = await chatStore.viewerURL(room: nil) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// `bubble.left.fill` sized to its own measured box rather than a point
    /// size, so the rendered glyph matches the design's icon box exactly.
    private func chatGlyph(color: Color) -> some View {
        Image(systemName: "bubble.left.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }

    /// Mauve, never a status color (the parity checklist's own rule), so a
    /// zoomed pane is never read as an agent state.
    ///
    /// The label is what makes this an accessibility element at all: an
    /// unlabelled `Image` is decorative, SwiftUI exposes nothing for it, and
    /// the identifier below then names something no reader can reach. This
    /// badge is the only place the window says a tab is zoomed, so it has to
    /// be readable.
    private var zoomBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(ChromeType.zoomBadge)
            .foregroundStyle(theme.mauve)
            .padding(.horizontal, ChromeMetrics.Pane.statusChipPadding)
            .frame(height: PaneChrome.titleRowHeight)
            .background(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).fill(theme.mauve.opacity(0.14)))
            .accessibilityLabel("Zoomed")
            .accessibilityIdentifier("flock.pane.zoomBadge.\(pane.paneID.rawValue)")
    }

    /// Status chips only accompany the active states (working/blocked/done);
    /// an idle or unknown pane shows no status in its title row.
    private var statusColor: Color? {
        theme.agentStatusColor(pane.agentStatus)
    }

    /// `ghosttySurface` mounts as soon as it exists, whether or not its
    /// bridge has painted a first frame yet -- libghostty needs a real
    /// window to render into, so a cold attach's surface has to be in the
    /// hierarchy (opacity 0, under the card) from the start, not swapped in
    /// only once ready. `hasFirstFrame` then just crossfades which of the
    /// two is the one actually visible; a warm (pool-seeded) surface starts
    /// this already `true`, so its card never appears at all.
    @ViewBuilder
    private func content(editorIsOpen: Bool) -> some View {
        if let ghosttySurface {
            ZStack(alignment: .top) {
                GhosttyPaneTerminalView(
                    surface: ghosttySurface, grid: grid, theme: theme, isFocused: isFocused,
                    fontSizePoints: fontSizePoints, optionAsAlt: optionAsAltStore.active,
                    rearrangeActive: rearrangeMode.active,
                    paneDragInProgress: drag.isPaneDragInFlight,
                    isPristineLauncherPane: viewModel.isPristineLauncherPane(pane.paneID),
                    // Any open editor, not just this pane's own: the one
                    // being typed into is usually a tab's or a rail row's,
                    // and this pane is the focused one whose surface would
                    // otherwise take the keystrokes.
                    editorIsOpen: editorIsOpen,
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
            // While the launcher shows, the surface below claims no point at
            // all (`GhosttySurfaceView.hitTest`), which also removes ITS own
            // click-to-focus for the body OUTSIDE the button row -- this is
            // that route's SwiftUI equivalent, pristine-only so an ordinary
            // live pane keeps going through the AppKit path exactly as
            // before. Checked fresh per tap, not cached: the launcher can
            // hide (a keystroke, real output) between this view updating and
            // the next click landing. Guarded the same way `title`'s own
            // tap is, so a right-click still opens the pane menu rather than
            // also firing a focus jump.
            .contentShape(Rectangle())
            .onTapGesture {
                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                guard !isFocused, viewModel.isPristineLauncherPane(pane.paneID) else { return }
                Task { await viewModel.jumpToHerdr(pane: pane.paneID) }
            }
            .animation(.easeOut(duration: 0.15), value: ghosttySurface.hasFirstFrame)
            .overlay(alignment: .bottomTrailing) {
                if let ownToast {
                    PaneCopiedToastPill(theme: theme, toast: ownToast)
                        .id(ownToast.id)
                        .padding(ChromeMetrics.Pane.toastInset)
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
    /// that are not the ghostty NSView (the card and the title). The
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
        VStack(alignment: .center, spacing: ChromeMetrics.Card.spacing) {
            Spacer(minLength: 0)
            Image(systemName: "terminal")
                .font(ChromeType.cardSymbol)
                .foregroundStyle(theme.textLabel)
            Text(cwdTail)
                .font(ChromeType.cardText)
                .foregroundStyle(theme.textDim)
            if let lastLine, !lastLine.isEmpty {
                Text(lastLine)
                    .font(ChromeType.cardText)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, ChromeMetrics.Card.lineHorizontalPadding)
                    .padding(.vertical, ChromeMetrics.Card.lineVerticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                            .fill(theme.pane)
                            .overlay(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(theme.rule, lineWidth: 1))
                    )
            }
            Text(hintText)
                .font(ChromeType.cardHint)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(ChromeMetrics.Card.padding)
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

/// The "Copied" whisper, shown only in the pane the copy happened in.
private struct PaneCopiedToastPill: View {
    let theme: Theme
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: ChromeMetrics.Toast.spacing) {
            Image(systemName: "doc.on.doc")
                .font(ChromeType.copiedSymbol)
                .foregroundStyle(theme.green)
            Text(toast.message)
                .font(ChromeType.copiedMessage)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, ChromeMetrics.Toast.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Toast.copiedVerticalPadding)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(theme.rule, lineWidth: 1))
        .shadow(color: theme.chrome.opacity(0.4), radius: ChromeMetrics.Toast.shadowRadius, y: ChromeMetrics.Toast.copiedShadowY)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }
}
