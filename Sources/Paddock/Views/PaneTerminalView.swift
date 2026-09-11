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
    /// The 1px divider between the dimmed history region and the live
    /// buffer -- `theme.separator`, threaded in as a plain `Color` like
    /// `terminalGround` rather than the whole `Theme`.
    let seamColor: SwiftUI.Color
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

    @State private var copiedLineCount: Int?
    @State private var historyCapable: Bool
    @State private var historyCapabilityToken: UUID?

    init(
        cols: Int, rows: Int, feed: PaneLiveFeed, terminalGround: SwiftUI.Color,
        onPlainClick: @escaping () -> Void, paneTerminal: PaneTerminal? = nil,
        onScreenActivity: ((Int) -> Void)? = nil, seamColor: SwiftUI.Color = .white.opacity(0.08)
    ) {
        self.cols = cols
        self.rows = rows
        self.feed = feed
        self.terminalGround = terminalGround
        self.onPlainClick = onPlainClick
        self.paneTerminal = paneTerminal
        self.onScreenActivity = onScreenActivity
        self.seamColor = seamColor
        _historyCapable = State(initialValue: paneTerminal?.historyCapable ?? false)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let paneTerminal, historyCapable {
                    PaneHistoryRegion(paneTerminal: paneTerminal, ground: terminalGround, seam: seamColor)
                }
                TerminalRepresentable(
                    cols: cols, rows: rows, feed: feed, onCopy: showCopyChip, onPlainClick: onPlainClick,
                    paneTerminal: paneTerminal, onScreenActivity: onScreenActivity, ground: terminalGround
                )
            }
            // The pane body is ONE ground color top to bottom (history
            // region + terminal + any inset): the pane's own background
            // catches any seam a child view's layout doesn't cover, on top
            // of `TerminalRepresentable` setting SwiftTerm's own
            // `nativeBackgroundColor` (its NSView otherwise paints pure
            // black regardless of anything drawn behind it).
            .background(terminalGround)

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

/// Plain, dimmed scrollback rendered above the styled live buffer, fetched on
/// demand via `PaneTerminal.loadOlderHistory`. Never touches `pane.scroll`:
/// herdr's own viewport is untouched by scrolling this region.
///
/// A `Color.clear` sentinel sits above the accumulated text inside a
/// `LazyVStack`; a plain `VStack` would realize (and fire `onAppear` for)
/// every child immediately regardless of scroll position, but a lazy one
/// only attaches a child once it nears the visible viewport -- so the
/// sentinel's `onAppear` fires exactly when the user scrolls this region to
/// its current top. It carries `.id(loadGeneration)`: each successful load
/// prepends a new chunk ABOVE the sentinel's position but does not move the
/// sentinel view itself, so without a fresh identity per load SwiftUI treats
/// it as the same child that already "appeared" once and never fires again
/// -- `loadGeneration` forces a new node each time so scrolling back up to
/// the (new) top re-triggers it.
private struct PaneHistoryRegion: View {
    let paneTerminal: PaneTerminal
    let ground: SwiftUI.Color
    let seam: SwiftUI.Color

    @State private var text = ""
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
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
            }
            // Starts (and snaps back to) the edge adjacent to the live
            // buffer rather than this region's own top: the sentinel that
            // triggers more loading sits at the top, so leaving the view
            // there by default re-fired it immediately on every load
            // (the "greedy" loop that also left a partial top row visibly
            // clipped by the fixed-height frame). Anchoring to the bottom
            // means the sentinel is off-screen until the user actually
            // scrolls up to it.
            .onChange(of: text) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .frame(maxHeight: 160)
        .background(ground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(seam).frame(height: 1)
        }
    }

    private func loadMore() {
        guard !isLoading else { return }
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
                // `.unsupported` and any transport failure: stop asking: the
                // affordance itself hides on the next render once
                // `paneTerminal.historyCapable` (checked by the parent view)
                // has flipped, or the pane is simply unreachable right now.
                reachedStart = true
            }
        }
    }
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

    final class Coordinator {
        var feedTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CopyOnSelectTerminalView {
        let view = CopyOnSelectTerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: cols, rows: rows))
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
