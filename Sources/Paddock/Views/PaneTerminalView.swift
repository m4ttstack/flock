import AppKit
import PaddockCore
import SwiftTerm
import SwiftUI

/// Live 1:1 rendering of one pane via SwiftTerm's own AppKit `TerminalView`
/// (real glyph rendering, scrollback, selection), fed the same backfill +
/// observe bytes `PaneTerminal` verifies headlessly in PaddockCoreTests.
/// The view is never made first responder anywhere in this file, so no
/// keystroke reaches SwiftTerm's input path at all -- typing is wired
/// explicitly via `send_input` at the pane-cell layer, above this view.
/// SwiftTerm's scrollback is entirely local to the view; nothing here ever
/// calls `pane.scroll`.
struct PaneTerminalView: View {
    let cols: Int
    let rows: Int
    let feed: PaneLiveFeed
    // SwiftTerm also exports a top-level `Color` (`Colors.swift`), so this
    // must stay qualified in any file that imports both it and SwiftUI.
    let terminalGround: SwiftUI.Color
    /// A click that ended with no selection: this view's stand-in for the
    /// canvas's normal click-to-focus, since a click landing on the AppKit
    /// terminal body never reaches SwiftUI's own tap gesture.
    let onPlainClick: () -> Void
    /// Backs the deep-history region and the pristine-launcher screen check.
    /// `nil` leaves this view with no region and no `pane.selection.read`
    /// traffic (used only by call sites, if any, that have no terminal to
    /// share -- production always passes one, owned per-pane by
    /// `SessionViewModel`).
    var paneTerminal: PaneTerminal?
    /// Fired with the current non-empty screen row count after every frame
    /// this view feeds into `paneTerminal`, so the pristine-launcher check
    /// sees real content rather than staying purely keystroke-driven.
    var onScreenActivity: ((Int) -> Void)?

    /// Legible-dim ink for history lines: quieter than live text but
    /// readable at a glance (the theme's overlay0), never system
    /// `.secondary`, which disappears against the terminal ground.
    let historyDim: SwiftUI.Color

    @State private var copiedLineCount: Int?
    @State private var historyCapable: Bool
    @State private var historyCapabilityToken: UUID?
    /// History is revealed by intent, not resident: scrolling up past the
    /// top of the live scrollback opens it; scrolling back down while the
    /// browser sits at its live end closes it. It is never a standing box.
    @State private var historyRevealed = false
    /// Shared with both the browser (writes) and the terminal view's
    /// guarded event monitor (reads), so the exit gesture inherits the
    /// same window + bounds scoping as the reveal gesture instead of
    /// needing an unguarded monitor of its own.
    @State private var browserState = BrowserScrollState()

    init(
        cols: Int, rows: Int, feed: PaneLiveFeed, terminalGround: SwiftUI.Color,
        onPlainClick: @escaping () -> Void, paneTerminal: PaneTerminal? = nil,
        onScreenActivity: ((Int) -> Void)? = nil,
        historyDim: SwiftUI.Color = SwiftUI.Color(red: 0.34, green: 0.37, blue: 0.54)
    ) {
        self.cols = cols
        self.rows = rows
        self.feed = feed
        self.terminalGround = terminalGround
        self.onPlainClick = onPlainClick
        self.paneTerminal = paneTerminal
        self.onScreenActivity = onScreenActivity
        self.historyDim = historyDim
        _historyCapable = State(initialValue: paneTerminal?.historyCapable ?? false)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TerminalRepresentable(
                cols: cols, rows: rows, feed: feed, onCopy: showCopyChip, onPlainClick: onPlainClick,
                paneTerminal: paneTerminal, onScreenActivity: onScreenActivity, ground: terminalGround,
                onScrollPastTop: { withAnimation(.easeOut(duration: 0.2)) { historyRevealed = true } },
                onScrollBackToLive: { withAnimation(.easeIn(duration: 0.15)) { historyRevealed = false } },
                browserState: browserState
            )
            // Content inset per the reference boards (9pt vertical, 11pt
            // horizontal inside the pane body); the shared pane ground
            // fills the inset so no band appears.
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            // ONE ground color for the whole body, on top of
            // `TerminalRepresentable` setting SwiftTerm's own
            // `nativeBackgroundColor` (its NSView otherwise paints pure
            // black regardless of anything drawn behind it).
            .background(terminalGround)

            // History browsing is a full-body overlay, never a stacked
            // box: the terminal keeps its size and feed beneath (no
            // resize, no viewport jump), and the browser is ONE scroll
            // surface where fetched history (dim) flows straight into the
            // buffer's own text, adjacency exact by construction because
            // that text is read from the rendered terminal itself.
            if let paneTerminal, historyCapable, historyRevealed {
                HistoryBrowseView(paneTerminal: paneTerminal, ground: terminalGround, ink: historyDim, state: browserState)
                    .transition(.opacity)
            }

            if let copiedLineCount {
                CopyChip(lineCount: copiedLineCount)
                    .padding(8)
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

    private func showCopyChip(lineCount: Int) {
        withAnimation(.easeOut(duration: 0.15)) { copiedLineCount = lineCount }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.3)) { copiedLineCount = nil }
        }
    }
}

private struct CopyChip: View {
    let lineCount: Int

    var body: some View {
        Text("Copied \(lineCount) line\(lineCount == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.7)))
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
    let state: BrowserScrollState

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
                            .padding(.horizontal, 11)
                            .padding(.vertical, 2)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                    }
                    Text(bufferText.isEmpty ? " " : bufferText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SwiftUI.Color(red: 0xC9 / 255, green: 0xCB / 255, blue: 0xD4 / 255))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
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

/// Bridges one `PaneLiveFeed` into a `CopyOnSelectTerminalView`. `makeNSView`
/// runs once per view identity (SwiftUI reuses the NSView across re-renders
/// via `updateNSView`), so the feed-consuming task starts exactly once here.
private struct TerminalRepresentable: NSViewRepresentable {
    let cols: Int
    let rows: Int
    let feed: PaneLiveFeed
    let onCopy: (Int) -> Void
    let onPlainClick: () -> Void
    /// Mirrors the same backfill + frames into the headless terminal that
    /// backs deep history and the pristine-launcher screen check -- fed
    /// from this single feed loop rather than a second consumer of
    /// `feed.frames`, since `AsyncStream` has no built-in fan-out.
    var paneTerminal: PaneTerminal?
    var onScreenActivity: ((Int) -> Void)?
    var ground: SwiftUI.Color
    var onScrollPastTop: (() -> Void)?
    var onScrollBackToLive: (() -> Void)?
    var browserState: BrowserScrollState?

    final class Coordinator {
        var feedTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CopyOnSelectTerminalView {
        // The history browser renders in SF Mono 11; the terminal must use
        // the IDENTICAL face and size or the browse boundary (and every
        // entry/exit) reads as a font change instead of a color change.
        let view = CopyOnSelectTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions(cols: cols, rows: rows))
        // Real herdr mouse reporting has no meaning here (there is no PTY
        // behind this view); selection must always stay paddock-local.
        view.allowMouseReporting = false
        view.onCopy = onCopy
        view.onPlainClick = onPlainClick
        // `TerminalView` paints its OWN opaque background from this
        // property (defaulting to plain black), independent of anything
        // SwiftUI draws behind the NSView -- a `.background()` modifier on
        // this representable is invisible wherever the terminal itself has
        // painted, which is everywhere its buffer cells are empty.
        view.nativeBackgroundColor = NSColor(ground)
        view.onScrollPastTop = onScrollPastTop
        view.onScrollBackToLive = onScrollBackToLive
        view.browserState = browserState
        // Deep-history adjacency is owed to what THIS view retains, not to
        // the headless mirror: the two SwiftTerm instances can diverge (a
        // full-frame reset lands at a different effective point in each
        // stream), so the anchor probes the rendered terminal directly.
        paneTerminal?.localRetentionProvider = { [weak view] in
            guard let view else { return 0 }
            return PaneTerminal.heldRowCount(of: view.terminal)
        }
        paneTerminal?.localRetainedTextProvider = { [weak view] in
            guard let view else { return "" }
            return PaneTerminal.retainedText(of: view.terminal)
        }
        let paneTerminal = self.paneTerminal
        let onScreenActivity = self.onScreenActivity
        // `paneTerminal` is seeded by `SessionViewModel.performAttach`
        // itself, synchronously before this feed ever reaches a view --
        // never redundantly here too, which would double-feed the same
        // backfill text into it. Only the SwiftTerm `view` below needs its
        // own separate feed (a different `Terminal` instance entirely).
        context.coordinator.feedTask = Task { @MainActor [weak view] in
            if let backfill = feed.backfillANSI {
                view?.feed(byteArray: [UInt8](backfill)[...])
            }
            for await frame in feed.frames {
                guard let view else { return }
                FrameFeeder.feed(
                    frame,
                    reset: { view.terminal.resetToInitialState() },
                    feed: { view.feed(byteArray: [UInt8]($0)[...]) }
                )
                if let paneTerminal {
                    paneTerminal.ingest(frame)
                    onScreenActivity?(paneTerminal.nonEmptyRowCount())
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: CopyOnSelectTerminalView, context: Context) {
        nsView.onCopy = onCopy
        nsView.onPlainClick = onPlainClick
        nsView.nativeBackgroundColor = NSColor(ground)
        nsView.onScrollPastTop = onScrollPastTop
        nsView.onScrollBackToLive = onScrollBackToLive
        nsView.browserState = browserState
        // `TerminalView` recomputes cols/rows from its own pixel frame on
        // every `setFrameSize` (per SwiftTerm's own doc comment: "cols and
        // rows... are otherwise recomputed from the frame size"), which
        // would silently diverge from the observe stream's dims -- exactly
        // spike 4's Caveat 1 top-crop failure mode. Force it back to the
        // authoritative layout-cell dims whenever they disagree.
        if nsView.terminal.cols != cols || nsView.terminal.rows != rows {
            nsView.resize(cols: cols, rows: rows)
        }
    }

    static func dismantleNSView(_ nsView: CopyOnSelectTerminalView, coordinator: Coordinator) {
        coordinator.feedTask?.cancel()
    }
}

/// Overrides `mouseUp` -- the one input-path member SwiftTerm's `TerminalView`
/// declares `open` (`keyDown` and `acceptsFirstResponder` are `public`, not
/// `open`, so a cross-module subclass cannot override either) -- to copy a
/// finished selection to the pasteboard immediately, matching herdr's own
/// copy-on-select convention. Selection never touches herdr: this only reads
/// SwiftTerm's local `SelectionService` and writes `NSPasteboard.general`.
final class CopyOnSelectTerminalView: TerminalView {
    var onCopy: ((Int) -> Void)?
    var onPlainClick: (() -> Void)?
    var onScrollPastTop: (() -> Void)?
    var onScrollBackToLive: (() -> Void)?
    var browserState: BrowserScrollState?
    private var lastEdgeSignal = Date.distantPast

    private var scrollMonitor: Any?

    /// Deep history reveals by intent: an up-scroll while the terminal is
    /// already at the very top of its local scrollback signals past-the-top;
    /// a down-scroll while sitting at the live bottom signals back-to-live.
    /// SwiftTerm declares `scrollWheel` public (not open), so a cross-module
    /// subclass cannot override it; a local event monitor observes the same
    /// events without touching SwiftTerm's own scrolling (the event is
    /// returned unmodified). Debounced because one trackpad flick delivers
    /// dozens of wheel events.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        } else if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEdge(event)
                return event
            }
        }
    }

    private func handleScrollEdge(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0, Date().timeIntervalSince(lastEdgeSignal) > 0.25 else { return }
        // Same sign convention as SwiftTerm's own scrollWheel: positive
        // delta scrolls up (toward older content), no inversion handling.
        let scrollingUp = deltaY > 0
        if let browserState, browserState.browsing {
            // While the history browser overlays this pane, the only edge
            // gesture is exit: down-scroll with the browser at its live end.
            if !scrollingUp, browserState.atLiveEnd {
                lastEdgeSignal = Date()
                onScrollBackToLive?()
            }
            return
        }
        let atTop = !canScroll || scrollPosition <= 0
        if scrollingUp, atTop {
            lastEdgeSignal = Date()
            onScrollPastTop?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if selection.active {
            let text = selection.getSelectedText()
            if !text.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
                onCopy?(lineCount)
                return
            }
        }
        onPlainClick?()
    }
}
