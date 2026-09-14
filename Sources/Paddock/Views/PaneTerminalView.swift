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
    let textSize: TerminalTextSize
    /// A left click (mouse-down) landed in this UNFOCUSED pane's body --
    /// wired to `SessionViewModel.jumpToHerdr(pane:)`. It is how herdr focus
    /// ever moves to this pane at all, since only the header row has its
    /// own tap gesture; an ALREADY-focused pane's body click (a drag-select
    /// start included) never fires this, since a real `pane.focus` RPC on
    /// every click into a pane the user is already working in would serve
    /// no purpose (see `GhosttySurfaceView.mouseDown`'s own gate).
    let onPrimaryClick: () -> Void

    init(
        surface: any GhosttyPaneSurface, theme: Theme, isFocused: Bool, textSize: TerminalTextSize,
        onPrimaryClick: @escaping () -> Void = {}
    ) {
        self.surface = surface
        self.theme = theme
        self.isFocused = isFocused
        self.textSize = textSize
        self.onPrimaryClick = onPrimaryClick
    }

    var body: some View {
        GhosttySurfaceRepresentable(
            surface: surface, theme: theme, isFocused: isFocused, textSize: textSize,
            onPrimaryClick: onPrimaryClick
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
    let textSize: TerminalTextSize
    var onPrimaryClick: () -> Void = {}

    final class Coordinator {
        var lastAppliedThemeID: String?
        var lastAppliedTextSize: TerminalTextSize?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let handle = surface as? GhosttySessionSurfaceHandle else {
            // Only reachable if `SessionViewModel`'s injected factory is
            // something other than `GhosttyControlSurfaceFactory` (a test
            // double, say) -- production always gets the real handle back.
            return PlaceholderGhosttyHostView(background: theme.terminalGround)
        }
        context.coordinator.lastAppliedThemeID = theme.id
        context.coordinator.lastAppliedTextSize = textSize
        let session = handle.session
        let view = GhosttySurfaceView(session: session)
        view.wantsFocus = isFocused
        view.onPrimaryClick = onPrimaryClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let ghosttyView = nsView as? GhosttySurfaceView else { return }
        if context.coordinator.lastAppliedThemeID != theme.id || context.coordinator.lastAppliedTextSize != textSize {
            context.coordinator.lastAppliedThemeID = theme.id
            context.coordinator.lastAppliedTextSize = textSize
            ghosttyView.session.updateAppearance(theme.ghosttyThemeColors(), textSize: textSize)
        }
        ghosttyView.wantsFocus = isFocused
        ghosttyView.onPrimaryClick = onPrimaryClick
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
