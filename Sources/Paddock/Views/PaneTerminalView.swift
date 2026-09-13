import AppKit
import PaddockCore
import SwiftUI

/// Live 1:1 rendering of one pane via a real libghostty surface whose PTY
/// child is a herdr-aware bridge process (`ControlBridge`) -- see
/// `GhosttyControlSurfaceFactory`. Input, mouse passthrough, clipboard and
/// resize all happen inside `GhosttySurfaceView`/`GhosttySession`
/// themselves; this wrapper only hosts the surface and keeps it restyled
/// when the active theme changes.
///
/// The deep-history browser overlays a full-body scroll surface: fetched
/// history (dim) flows straight into the buffer's own retained text (regular
/// ink), snapshotted from libghostty's own retained screen
/// (`GhosttySession.retainedRowCount`/`retainedText`) -- there is only ever
/// one buffer for a pane to disagree with itself about.
struct GhosttyPaneTerminalView: View {
    let surface: any GhosttyPaneSurface
    let theme: Theme
    let isFocused: Bool
    /// One truth for every ghostty surface's `font-size` and the history
    /// overlay's own font, so the deep-history seam stays color-only. See
    /// `historyRowPitch`, which pins the overlay's per-row CONTAINER height
    /// to the surface's real `cell_height_px` at this size -- not a
    /// `.lineSpacing` added on top of the font's own natural line height,
    /// which can only grow the pitch and so cannot correct for a cell
    /// SHORTER than that natural height (the default 13pt case).
    let textSize: TerminalTextSize
    /// A left click (mouse-down) landed in this UNFOCUSED pane's body --
    /// wired to `SessionViewModel.jumpToHerdr(pane:)`. It is how herdr focus
    /// ever moves to this pane at all, since only the header row has its
    /// own tap gesture; an ALREADY-focused pane's body click (a drag-select
    /// start included) never fires this, since a real `pane.focus` RPC on
    /// every click into a pane the user is already working in would serve
    /// no purpose (see `GhosttySurfaceView.mouseDown`'s own gate).
    let onPrimaryClick: () -> Void
    /// Backs the deep-history region, shared with `SessionViewModel`'s
    /// per-pane cache. `nil` leaves this view with no region.
    var paneTerminal: PaneTerminal?
    let historyDim: SwiftUI.Color

    @State private var historyCapable: Bool
    @State private var historyCapabilityToken: UUID?
    /// History is revealed by intent, not resident: scrolling up past the
    /// top of the live scrollback opens it; scrolling back down while the
    /// browser sits at its live end closes it. It is never a standing box.
    @State private var historyRevealed = false
    @State private var browserState = BrowserScrollState()

    init(
        surface: any GhosttyPaneSurface, theme: Theme, isFocused: Bool, textSize: TerminalTextSize,
        onPrimaryClick: @escaping () -> Void = {},
        paneTerminal: PaneTerminal? = nil,
        historyDim: SwiftUI.Color = SwiftUI.Color(red: 0.34, green: 0.37, blue: 0.54)
    ) {
        self.surface = surface
        self.theme = theme
        self.isFocused = isFocused
        self.textSize = textSize
        self.onPrimaryClick = onPrimaryClick
        self.paneTerminal = paneTerminal
        self.historyDim = historyDim
        _historyCapable = State(initialValue: paneTerminal?.historyCapable ?? false)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GhosttySurfaceRepresentable(
                surface: surface, theme: theme, isFocused: isFocused, textSize: textSize,
                onPrimaryClick: onPrimaryClick,
                paneTerminal: paneTerminal,
                browserState: browserState,
                onScrollPastTop: { withAnimation(.easeOut(duration: 0.2)) { historyRevealed = true } },
                onScrollBackToLive: { withAnimation(.easeIn(duration: 0.15)) { historyRevealed = false } }
            )

            if let paneTerminal, historyCapable, historyRevealed {
                HistoryBrowseView(
                    paneTerminal: paneTerminal, ground: theme.terminalGround, ink: historyDim,
                    liveInk: theme.terminalForeground, state: browserState,
                    fontSize: CGFloat(textSize.points), rowPitch: historyRowPitch
                )
                .transition(.opacity)
            }
        }
        // Reactive, not polled: `historyCapable` only ever transitions
        // true -> false (the gate never recovers), so registering once per
        // view identity is enough -- a listener added after the flip
        // already happened is a documented no-op on the gate side, matched
        // here by seeding `historyCapable` from the CURRENT value above.
        .onAppear {
            historyCapabilityToken = paneTerminal?.onHistoryCapabilityLost {
                Task { @MainActor in historyCapable = false }
            }
        }
        .onDisappear {
            if let historyCapabilityToken {
                paneTerminal?.removeHistoryCapabilityListener(historyCapabilityToken)
            }
        }
    }

    /// The overlay's exact per-row container height: `surfaceGeometry()`'s
    /// `cell_height_px` (already rounded to a whole device pixel by ghostty
    /// itself) converted to points via `TerminalRowPitch`, using the hosting
    /// window's REAL `backingScaleFactor` -- never an assumed 2x. Falls back
    /// to the font's own natural line height only before the surface (or its
    /// window) exists, since there is no real cell height to read yet.
    private var historyRowPitch: CGFloat {
        guard let handle = surface as? GhosttySessionSurfaceHandle,
              let geometry = handle.session.surfaceGeometry()
        else { return fontLineHeight(size: CGFloat(textSize.points)) }
        let scale = handle.session.view?.window?.backingScaleFactor
            ?? handle.session.view?.window?.screen?.backingScaleFactor
            ?? 2
        return CGFloat(TerminalRowPitch.points(cellHeightPx: geometry.cellPixels.height, scale: Double(scale)))
    }
}

/// `Menlo`'s own natural line height at `size` -- used ONLY as the
/// no-surface-yet fallback for `historyRowPitch` above, never as part of the
/// real pitch calculation once a surface exists (that calculation is pixel-
/// exact and font-metric-independent by design; see `TerminalRowPitch`).
private func fontLineHeight(size: CGFloat) -> CGFloat {
    guard let font = NSFont(name: TerminalFont.face, size: size) else { return size * 1.2 }
    return font.ascender - font.descender + font.leading
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
    var paneTerminal: PaneTerminal?
    var browserState: BrowserScrollState?
    var onScrollPastTop: (() -> Void)?
    var onScrollBackToLive: (() -> Void)?

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
        view.onScrollPastTop = onScrollPastTop
        view.onScrollBackToLive = onScrollBackToLive
        view.browserState = browserState
        // Deep-history adjacency reads straight from libghostty's own
        // retained screen (see `GhosttySession.retainedText`'s doc) -- there
        // is only ever one buffer for this pane.
        paneTerminal?.localRetentionProvider = { [weak session] in session?.retainedRowCount() ?? 0 }
        paneTerminal?.localRetainedTextProvider = { [weak session] in session?.retainedText() ?? "" }
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
        ghosttyView.onScrollPastTop = onScrollPastTop
        ghosttyView.onScrollBackToLive = onScrollBackToLive
        ghosttyView.browserState = browserState
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

/// Full-body history browser: one scroll surface where deep history fetched
/// via `PaneTerminal.loadOlderHistory` (dim ink) flows directly into the live
/// buffer's own retained text (regular ink), snapshotted from the RENDERED
/// terminal at reveal time. Never touches `pane.scroll`: herdr's viewport is
/// untouched by anything here.
///
/// A `Color.clear` sentinel above the text inside a `LazyVStack` drives
/// loading: lazy realization means its `onAppear` fires only when the user
/// scrolls to the current top; `.id(loadGeneration)` gives it a fresh
/// identity per completed load so it can fire again (a prepend does not move
/// the sentinel, so SwiftUI would otherwise treat it as already appeared).
/// Exit is by intent, mirroring reveal: a down-scroll while the bottom
/// sentinel is visible (the browser sits at its live end) hands control back
/// to the live terminal underneath, which kept its feed and size the whole
/// time.
private struct HistoryBrowseView: View {
    let paneTerminal: PaneTerminal
    let ground: SwiftUI.Color
    let ink: SwiftUI.Color
    /// The live buffer's own ink, matching the terminal's active
    /// `terminalForeground` role -- the browse boundary stays color-only
    /// (dim history vs. this) even as the theme changes.
    let liveInk: SwiftUI.Color
    let state: BrowserScrollState
    /// The identical face/size the ghostty surface itself renders at (see
    /// `TerminalFont`), and the exact per-row container height
    /// (`GhosttyPaneTerminalView.historyRowPitch`) every row below is pinned
    /// to -- the history/live boundary is a color change only, never a
    /// glyph-size or row-pitch one.
    let fontSize: CGFloat
    let rowPitch: CGFloat

    @State private var text = ""
    @State private var bufferText = ""
    @State private var isLoading = false
    @State private var reachedStart = false
    @State private var showsChangedNotice = false
    @State private var loadGeneration = 0

    private static let bottomAnchor = "paddock.history.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !reachedStart {
                        Color.clear.frame(height: 1).id(loadGeneration).onAppear(perform: loadMore)
                    }
                    if showsChangedNotice {
                        Text("History changed while loading; older lines may be out of order.")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.vertical, 2)
                    }
                    ForEach(Array(historyLines.enumerated()), id: \.offset) { _, line in
                        row(line, ink: ink)
                    }
                    ForEach(Array(bufferLines.enumerated()), id: \.offset) { _, line in
                        row(line, ink: liveInk)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                        .onAppear { state.atLiveEnd = true }
                        .onDisappear { state.atLiveEnd = false }
                }
                .padding(.vertical, 9)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                bufferText = paneTerminal.localRetainedTextProvider?() ?? ""
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ground)
        .onAppear {
            state.browsing = true
            state.atLiveEnd = true
        }
        .onDisappear { state.browsing = false }
    }

    /// One history/live row, pinned to the EXACT container height
    /// `rowPitch` gives -- never `.lineSpacing` atop the font's own natural
    /// line height (see `TerminalRowPitch`'s doc comment for why that drifts
    /// at the default size). `.lineLimit(1)` keeps a real terminal row,
    /// which is already single-line by construction, from ever wrapping
    /// inside its fixed-height container. No horizontal padding here: the
    /// surface has `window-padding-x = 0` and `PaneCellView.contentInsets`
    /// already supplies the ONE shared inset both renderers sit inside, so
    /// an inset here would double it and shift the overlay's column 0 off
    /// the surface's own.
    private func row(_ line: String, ink: SwiftUI.Color) -> some View {
        Text(line.isEmpty ? " " : line)
            .font(.custom(TerminalFont.face, size: fontSize))
            .lineLimit(1)
            .foregroundStyle(ink)
            .frame(height: rowPitch, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `text` (the fetched-history block, newline-joined by
    /// `PaneTerminal.historyText`) split back into one string per real row --
    /// `historyLines`/`bufferLines` are what `row(_:ink:)` iterates so each
    /// row gets its OWN fixed-height container instead of one `Text` whose
    /// internal line spacing would otherwise decide the pitch.
    private var historyLines: [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// The live buffer's own rows, split the same way -- `" "` (a single
    /// blank row) when the buffer itself is empty, matching the prior
    /// single-`Text` behavior's placeholder so the overlay is never a
    /// zero-height gap before the surface reports any content.
    private var bufferLines: [String] {
        (bufferText.isEmpty ? " " : bufferText).components(separatedBy: "\n")
    }

    private func loadMore() {
        guard !isLoading, !reachedStart else { return }
        isLoading = true
        Task {
            defer {
                isLoading = false
                loadGeneration += 1
            }
            do {
                let more = try await paneTerminal.loadOlderHistory(chunkRows: 200)
                text = paneTerminal.historyText
                if !more { reachedStart = true }
            } catch PaneHistoryError.contentChanged {
                showsChangedNotice = true
                text = paneTerminal.historyText
            } catch {
                // `.unsupported` and any transport failure: stop asking; the
                // affordance hides once `historyCapable` flips, or the pane
                // is simply unreachable right now.
                reachedStart = true
            }
        }
    }
}

/// Scroll coupling between the history browser overlay and the terminal
/// view's guarded event monitor: the browser records whether it is open and
/// sitting at its live end; the monitor turns a down-scroll in that state
/// into the exit signal, with the same window + bounds scoping the reveal
/// gesture gets.
final class BrowserScrollState {
    var browsing = false
    var atLiveEnd = true
}

