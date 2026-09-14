import AppKit
import PaddockCore
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
    let theme: Theme
    let isFocused: Bool
    /// The Terminal Text size every pane shares.
    let fontSizePoints: Double
    /// `RearrangeMode.active`: while true, `GhosttySurfaceView` forwards no
    /// mouse event to the terminal.
    let rearrangeActive: Bool
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
    /// reach the drag space.
    let onBodyDrag: (PaneBodyDragEvent) -> Void

    init(
        surface: any GhosttyPaneSurface, theme: Theme, isFocused: Bool, fontSizePoints: Double,
        rearrangeActive: Bool = false,
        onPrimaryClick: @escaping () -> Void = {}, menuProvider: @escaping () -> NSMenu? = { nil },
        onBodyDrag: @escaping (PaneBodyDragEvent) -> Void = { _ in }
    ) {
        self.surface = surface
        self.theme = theme
        self.isFocused = isFocused
        self.fontSizePoints = fontSizePoints
        self.rearrangeActive = rearrangeActive
        self.onPrimaryClick = onPrimaryClick
        self.menuProvider = menuProvider
        self.onBodyDrag = onBodyDrag
    }

    var body: some View {
        GhosttySurfaceRepresentable(
            surface: surface, theme: theme, isFocused: isFocused, fontSizePoints: fontSizePoints,
            rearrangeActive: rearrangeActive, onPrimaryClick: onPrimaryClick, menuProvider: menuProvider,
            onBodyDrag: onBodyDrag
        )
    }
}

/// Hosts one `GhosttySurfaceView`, created once per surface identity
/// (`makeNSView` runs once; SwiftUI reuses it across re-renders via
/// `updateNSView`). `surface` is the type-erased `GhosttyPaneSurface`
/// `SessionViewModel` hands back from `attachPane` -- downcast here, in the
/// app layer, to reach the real `GhosttySession` PaddockCore is never
/// allowed to see.
private struct GhosttySurfaceRepresentable: NSViewRepresentable {
    let surface: any GhosttyPaneSurface
    let theme: Theme
    let isFocused: Bool
    let fontSizePoints: Double
    var rearrangeActive: Bool = false
    var onPrimaryClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }
    var onBodyDrag: (PaneBodyDragEvent) -> Void = { _ in }

    final class Coordinator {
        var lastAppliedThemeID: String?
        var lastAppliedFontSize: Double?
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
            if session.configuration.themeColors != incomingColors || session.configuration.fontSizePoints != fontSizePoints {
                session.updateAppearance(incomingColors, fontSizePoints: fontSizePoints)
            }
            context.coordinator.lastAppliedThemeID = theme.id
            context.coordinator.lastAppliedFontSize = fontSizePoints
            existingView.wantsFocus = isFocused
            existingView.rearrangeActive = rearrangeActive
            existingView.onPrimaryClick = onPrimaryClick
            existingView.paneMenuProvider = menuProvider
            existingView.onBodyDrag = onBodyDrag
            return existingView
        }
        context.coordinator.lastAppliedThemeID = theme.id
        context.coordinator.lastAppliedFontSize = fontSizePoints
        let view = GhosttySurfaceView(session: session)
        view.wantsFocus = isFocused
        view.rearrangeActive = rearrangeActive
        view.onPrimaryClick = onPrimaryClick
        view.paneMenuProvider = menuProvider
        view.onBodyDrag = onBodyDrag
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let ghosttyView = nsView as? GhosttySurfaceView else { return }
        if context.coordinator.lastAppliedThemeID != theme.id || context.coordinator.lastAppliedFontSize != fontSizePoints {
            context.coordinator.lastAppliedThemeID = theme.id
            context.coordinator.lastAppliedFontSize = fontSizePoints
            ghosttyView.session.updateAppearance(theme.ghosttyThemeColors(), fontSizePoints: fontSizePoints)
        }
        ghosttyView.wantsFocus = isFocused
        ghosttyView.rearrangeActive = rearrangeActive
        ghosttyView.onPrimaryClick = onPrimaryClick
        // Rebuilt every `updateNSView` (never applied only once at
        // `makeNSView`): the closure itself is stable in shape but must read
        // the CURRENT view model/pane, since `paneMenuProvider` is only ever
        // called later, at the moment of a real right-click.
        ghosttyView.paneMenuProvider = menuProvider
        // Rebuilt every pass for the same reason as the menu provider: the
        // closure has to read the CURRENT pane frame when a drag actually
        // starts, not the one this view was first made with.
        ghosttyView.onBodyDrag = onBodyDrag
        // Mirrors real AppKit first-responder status: becoming the
        // resolved-focused pane grabs real AppKit key focus immediately,
        // with no extra click needed first. The PRIMARY grab happens in
        // `GhosttySurfaceView.viewDidMoveToWindow` (the point `window` is
        // guaranteed non-nil); this is a best-effort follow-up for a later
        // flip while the view already has one.
        if isFocused, ghosttyView.window != nil, ghosttyView.window?.firstResponder !== ghosttyView {
            ghosttyView.requestFocus()
        }
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
