import AppKit
import PaddockCore
import SwiftTerm
import SwiftUI

/// Live 1:1 rendering of one pane via SwiftTerm's own AppKit `TerminalView`
/// (real glyph rendering, scrollback, selection), fed the same backfill +
/// observe bytes `PaneTerminal` verifies headlessly in PaddockCoreTests.
/// Read-only for Task 18: the view is never made first responder anywhere in
/// this file, so no keystroke reaches SwiftTerm's input path at all (Task
/// 18c wires typing explicitly via `send_input`, not through this view).
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
    /// Backs the deep-history region (Task 18b). `nil` leaves this view
    /// exactly as Task 18 left it: no region, no `pane.selection.read`
    /// traffic. Production wiring (a shared `PaneTerminal` per pane, fed a
    /// session-wide `HistoryCapabilityGate`) is follow-up work; no call site
    /// passes one yet.
    var paneTerminal: PaneTerminal?

    @State private var copiedLineCount: Int?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let paneTerminal, paneTerminal.historyCapable {
                    PaneHistoryRegion(paneTerminal: paneTerminal)
                }
                TerminalRepresentable(cols: cols, rows: rows, feed: feed, onCopy: showCopyChip, onPlainClick: onPlainClick)
                    .background(terminalGround)
            }

            if let copiedLineCount {
                CopyChip(lineCount: copiedLineCount)
                    .padding(8)
                    .transition(.opacity)
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
/// its current top, which is the "past the top" trigger the brief asks for.
private struct PaneHistoryRegion: View {
    let paneTerminal: PaneTerminal

    @State private var text = ""
    @State private var isLoading = false
    @State private var reachedStart = false
    @State private var showsChangedNotice = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !reachedStart {
                    Color.clear.frame(height: 1).onAppear(perform: loadMore)
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
            }
        }
        .frame(maxHeight: 160)
    }

    private func loadMore() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
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
            }
        }
        return view
    }

    func updateNSView(_ nsView: CopyOnSelectTerminalView, context: Context) {
        nsView.onCopy = onCopy
        nsView.onPlainClick = onPlainClick
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
