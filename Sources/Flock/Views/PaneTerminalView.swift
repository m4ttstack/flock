import AppKit
import FlockCore
import SwiftUI

/// Live 1:1 rendering of one pane via a real libghostty surface whose PTY
/// child is a herdr-aware bridge process (`ControlBridge`) -- see
/// `GhosttyControlSurfaceFactory`. Input, mouse passthrough, clipboard,
/// scroll (through herdr's real viewport, never a local scrollback -- herdr
/// streams viewport repaints, so libghostty holds none of its own) and
/// resize all happen inside `GhosttySurfaceView`/`GhosttySession` themselves;
/// this wrapper only hosts the surface and keeps it restyled when the active
/// theme changes.
struct GhosttyPaneTerminalView: View {
    let surface: any GhosttyPaneSurface
    /// The box grid the surface is framed at, for the grid log only.
    let grid: PTYSize
    let theme: Theme
    let isFocused: Bool
    /// The Terminal Text size every pane shares.
    let fontSizePoints: Double
    /// Whether Option acts as Alt, and on which key, every pane shares.
    let optionAsAlt: OptionAsAlt
    /// `RearrangeMode.active`: while true, `GhosttySurfaceView` forwards no
    /// mouse event to the terminal.
    let rearrangeActive: Bool
    /// Where a plain right-click goes while the pane's program has the mouse.
    let rightClickMode: RightClickMode
    /// `DragCoordinator.isPaneDragInFlight`: while true the cursor is
    /// closed-hand everywhere, not just over this pane.
    let paneDragInProgress: Bool
    /// `SessionViewModel.isPristineLauncherPane`: while true this pane's
    /// surface claims no mouse point at all, so `PaneLauncherOverlay`'s
    /// button row (drawn above it in SwiftUI) receives clicks and hover.
    let isPristineLauncherPane: Bool
    /// `SessionViewModel.renameTarget != nil`: while an inline editor is
    /// open anywhere in the window, this pane's surface makes no
    /// first-responder claim of its own.
    let editorIsOpen: Bool
    /// A left click (mouse-down) landed in this UNFOCUSED pane's body --
    /// wired to `SessionViewModel.jumpToHerdr(pane:)`. It is how herdr focus
    /// ever moves to this pane at all, since only the header row has its
    /// own tap gesture; an ALREADY-focused pane's body click (a drag-select
    /// start included) never fires this, since a real `pane.focus` RPC on
    /// every click into a pane the user is already working in would serve
    /// no purpose (see `GhosttySurfaceView.mouseDown`'s own gate).
    let onPrimaryClick: () -> Void
    /// Builds this pane's right-click `NSMenu` on demand -- see
    /// `GhosttySurfaceView.menu(for:)`, the only place it is actually called.
    let menuProvider: () -> NSMenu?
    /// A grab that became a drag in the pane body, with its point in the
    /// body's own top-left space -- the caller adds the body's own origin to
    /// reach the drag space. Called once, at the start; the drag itself
    /// belongs to `DragCoordinator` from then on.
    let onBodyDragBegan: (CGPoint) -> Void

    @State private var findBarFrame: CGRect?

    private static let space = "flock.pane.terminal"

    init(
        surface: any GhosttyPaneSurface, grid: PTYSize, theme: Theme, isFocused: Bool, fontSizePoints: Double,
        optionAsAlt: OptionAsAlt,
        rearrangeActive: Bool = false, rightClickMode: RightClickMode = .program,
        paneDragInProgress: Bool = false, isPristineLauncherPane: Bool = false,
        editorIsOpen: Bool = false,
        onPrimaryClick: @escaping () -> Void = {}, menuProvider: @escaping () -> NSMenu? = { nil },
        onBodyDragBegan: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.surface = surface
        self.grid = grid
        self.theme = theme
        self.isFocused = isFocused
        self.fontSizePoints = fontSizePoints
        self.optionAsAlt = optionAsAlt
        self.rearrangeActive = rearrangeActive
        self.rightClickMode = rightClickMode
        self.paneDragInProgress = paneDragInProgress
        self.isPristineLauncherPane = isPristineLauncherPane
        self.editorIsOpen = editorIsOpen
        self.onPrimaryClick = onPrimaryClick
        self.menuProvider = menuProvider
        self.onBodyDragBegan = onBodyDragBegan
    }

    private var session: GhosttySession? { (surface as? GhosttySessionSurfaceHandle)?.session }

    var body: some View {
        let search = session?.search
        let findBarOpen = search?.isOpen == true
        ZStack(alignment: .topTrailing) {
            GhosttySurfaceRepresentable(
                surface: surface, grid: grid, theme: theme, isFocused: isFocused, fontSizePoints: fontSizePoints,
                optionAsAlt: optionAsAlt,
                rearrangeActive: rearrangeActive, rightClickMode: rightClickMode,
                paneDragInProgress: paneDragInProgress, isPristineLauncherPane: isPristineLauncherPane,
                // The find field is an editor too: while it holds the
                // keyboard, this pane's terminal must not take it back.
                editorIsOpen: editorIsOpen || search?.fieldHasFocus == true,
                findBarFrame: findBarOpen ? findBarFrame : nil,
                onPrimaryClick: onPrimaryClick, menuProvider: menuProvider, onBodyDragBegan: onBodyDragBegan
            )
            if let session, let search, findBarOpen {
                TerminalFindBar(
                    theme: theme, search: search,
                    onSearch: { session.searchFor($0) },
                    onNavigate: { session.navigateSearch(forward: $0) },
                    onClose: { session.endSearch() }
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { findBarFrame = $0 }
                .padding(ChromeMetrics.FindBar.inset)
            }
        }
        .coordinateSpace(name: Self.space)
    }
}

/// Hosts one `GhosttySurfaceView`, created once per surface identity
/// (`makeNSView` runs once; SwiftUI reuses it across re-renders via
/// `updateNSView`). `surface` is the type-erased `GhosttyPaneSurface`
/// `SessionViewModel` hands back from `attachPane` -- downcast here, in the
/// app layer, to reach the real `GhosttySession` FlockCore is never
/// allowed to see.
private struct GhosttySurfaceRepresentable: NSViewRepresentable {
    let surface: any GhosttyPaneSurface
    let grid: PTYSize
    let theme: Theme
    let isFocused: Bool
    let fontSizePoints: Double
    let optionAsAlt: OptionAsAlt
    var rearrangeActive: Bool = false
    var rightClickMode: RightClickMode = .program
    var paneDragInProgress: Bool = false
    var isPristineLauncherPane: Bool = false
    var editorIsOpen: Bool = false
    var findBarFrame: CGRect?
    var onPrimaryClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }
    var onBodyDragBegan: (CGPoint) -> Void = { _ in }

    final class Coordinator {
        var lastAppliedThemeID: String?
        var lastAppliedFontSize: Double?
        var lastAppliedOptionAsAlt: OptionAsAlt?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Returns the session's EXISTING view when it already has one -- a
    /// pane re-hosted after a park, whose surface (and view) survived the
    /// tab switch that took it off screen -- rather than creating a second
    /// one. SwiftUI then re-parents the same `NSView` instance into the new
    /// hierarchy; `viewDidMoveToWindow` (already idempotent) re-syncs it.
    ///
    /// A fresh `Coordinator` accompanies this call (SwiftUI made a brand new
    /// `GhosttySurfaceRepresentable` identity for the reappearing tab), so
    /// its `lastApplied*` start `nil` regardless of branch -- unconditionally
    /// stamping them to the CURRENT `theme`/`fontSizePoints` here would tell
    /// `updateNSView` "already applied" even when the re-hosted session's own
    /// last-applied appearance (`session.configuration`, kept current by
    /// every `updateAppearance` call) is stale from before the park -- a
    /// theme or font-size change made on another tab while this pane was
    /// parked would then never repaint it. So the re-host branch compares
    /// against the session's OWN record and applies immediately when it
    /// differs, before ever touching the coordinator.
    func makeNSView(context: Context) -> NSView {
        guard let handle = surface as? GhosttySessionSurfaceHandle else {
            // Only reachable if `SessionViewModel`'s injected factory is
            // something other than `GhosttyControlSurfaceFactory` (a test
            // double, say) -- production always gets the real handle back.
            return PlaceholderGhosttyHostView(background: theme.terminalGround)
        }
        let session = handle.session
        session.setExpectedGrid(cols: grid.cols, rows: grid.rows)
        if let existingView = session.view {
            // unparked here, synchronously, rather than waiting for
            // `SessionViewModel.attachPane`'s own chained `existing.unpark()`
            // to run -- that call is queued behind `paneWork` and can settle
            // AFTER this view is already back in the window, which would let
            // one `ghostty_surface_draw` land while the surface still
            // believes it is occluded (`GhosttySurfaceView.layout()` ->
            // `requestRender()` fires from `viewDidMoveToWindow` before the
            // chained unpark ever runs). Idempotent, so calling it again
            // once the chained one does run is a harmless no-op.
            handle.unpark()
            let incomingColors = theme.ghosttyThemeColors()
            if session.configuration.themeColors != incomingColors
                || session.configuration.fontSizePoints != fontSizePoints
                || session.configuration.optionAsAlt != optionAsAlt {
                session.updateAppearance(incomingColors, fontSizePoints: fontSizePoints, optionAsAlt: optionAsAlt)
            }
            context.coordinator.lastAppliedThemeID = theme.id
            context.coordinator.lastAppliedFontSize = fontSizePoints
            context.coordinator.lastAppliedOptionAsAlt = optionAsAlt
            existingView.wantsFocus = isFocused
            existingView.rearrangeActive = rearrangeActive
            existingView.rightClickMode = rightClickMode
            existingView.paneDragInProgress = paneDragInProgress
            existingView.isPristineLauncherPane = isPristineLauncherPane
            existingView.editorIsOpen = editorIsOpen
            existingView.findBarFrame = findBarFrame
            existingView.onPrimaryClick = onPrimaryClick
            existingView.paneMenuProvider = menuProvider
            existingView.onBodyDragBegan = onBodyDragBegan
            return existingView
        }
        context.coordinator.lastAppliedThemeID = theme.id
        context.coordinator.lastAppliedFontSize = fontSizePoints
        context.coordinator.lastAppliedOptionAsAlt = optionAsAlt
        let view = GhosttySurfaceView(session: session)
        view.wantsFocus = isFocused
        view.rearrangeActive = rearrangeActive
        view.rightClickMode = rightClickMode
        view.paneDragInProgress = paneDragInProgress
        view.isPristineLauncherPane = isPristineLauncherPane
        view.editorIsOpen = editorIsOpen
        view.findBarFrame = findBarFrame
        view.onPrimaryClick = onPrimaryClick
        view.paneMenuProvider = menuProvider
        view.onBodyDragBegan = onBodyDragBegan
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let ghosttyView = nsView as? GhosttySurfaceView else { return }
        ghosttyView.session.setExpectedGrid(cols: grid.cols, rows: grid.rows)
        if context.coordinator.lastAppliedThemeID != theme.id
            || context.coordinator.lastAppliedFontSize != fontSizePoints
            || context.coordinator.lastAppliedOptionAsAlt != optionAsAlt {
            context.coordinator.lastAppliedThemeID = theme.id
            context.coordinator.lastAppliedFontSize = fontSizePoints
            context.coordinator.lastAppliedOptionAsAlt = optionAsAlt
            ghosttyView.session.updateAppearance(
                theme.ghosttyThemeColors(), fontSizePoints: fontSizePoints, optionAsAlt: optionAsAlt
            )
        }
        ghosttyView.wantsFocus = isFocused
        ghosttyView.rearrangeActive = rearrangeActive
        ghosttyView.rightClickMode = rightClickMode
        ghosttyView.paneDragInProgress = paneDragInProgress
        ghosttyView.isPristineLauncherPane = isPristineLauncherPane
        // Set before the claim below reads it, never after: the whole point
        // of the flag is to be current at the instant that claim is decided.
        ghosttyView.editorIsOpen = editorIsOpen
        ghosttyView.findBarFrame = findBarFrame
        ghosttyView.onPrimaryClick = onPrimaryClick
        // Rebuilt every `updateNSView` (never applied only once at
        // `makeNSView`): the closure itself is stable in shape but must read
        // the CURRENT view model/pane, since `paneMenuProvider` is only ever
        // called later, at the moment of a real right-click.
        ghosttyView.paneMenuProvider = menuProvider
        // Rebuilt every pass for the same reason as the menu provider: the
        // closure has to read the CURRENT pane frame when a drag actually
        // starts, not the one this view was first made with.
        ghosttyView.onBodyDragBegan = onBodyDragBegan
        // Mirrors real AppKit first-responder status: becoming the
        // resolved-focused pane grabs real AppKit key focus immediately, with
        // no extra click needed first, and an editor opening over it is
        // handed that focus back. The PRIMARY pass is
        // `GhosttySurfaceView.viewDidMoveToWindow` (the point `window` is
        // guaranteed non-nil); this is the follow-up for every later flip
        // while the view already has one.
        //
        // This pass runs far more often than a focus change does -- every
        // pane cell re-renders whenever ANY pane's record moves, and whenever
        // an inline editor opens, since they all read `renameTarget` -- so
        // which of those passes does anything is `TerminalFocusClaim`'s to
        // decide, never this call site's.
        ghosttyView.syncFocusClaim()
    }
}

/// What a ghostty pane shows before its surface exists (a nil `handle`
/// downcast only, per `GhosttySurfaceRepresentable.makeNSView`'s comment) --
/// just the theme's terminal ground, the same placeholder color
/// `GhosttySurfaceView` itself paints while its own surface is still nil.
private final class PlaceholderGhosttyHostView: NSView {
    init(background: SwiftUI.Color) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(background).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
