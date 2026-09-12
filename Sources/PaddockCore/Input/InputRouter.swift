import Foundation

/// Named keys `pane.send_input` accepts verbatim in its `keys` array,
/// matching herdr's bare (no-modifier) lowercase key names
/// (`config/keybinds.rs`'s `parse_key_combo`): enter, esc, up, down, left,
/// right, backspace, tab.
public enum InputKey: String, Sendable {
    case enter, esc, up, down, left, right, backspace, tab
}

/// Batches plain keystrokes for one pane into `pane.send_input` calls and
/// forwards named keys and control combos. Scoped to the paddock-focused
/// pane by construction, not by a runtime check: callers (the SwiftUI
/// key-capture layer) create/use one router per pane and only route events
/// into the one belonging to the resolved focused pane.
///
/// Plain characters accumulate in a pending batch and flush as one `text`
/// send_input call after a short debounce of quiet, OR immediately -- text
/// first, then the key -- when a named key or control combo arrives, so
/// typing "ls" then Enter reaches the wire as `text:"ls"` followed by
/// `keys:["enter"]`, never interleaved or reordered.
///
/// `isRenaming`/`isDragLive` gate every send. Both default `false`: no
/// inline-rename or drag-and-drop surface exists yet in paddock, so neither
/// ever flips today, but the checks are wired now so that future task only
/// has to set the flag.
@MainActor
public final class InputRouter {
    /// The brief describes a control combo's wire form as `"ctrl-<char>"`,
    /// but herdr's real parser disagrees: `app/api_helpers.rs`'s
    /// `normalize_api_key_alias` only special-cases the literal `"C-c"`/
    /// `"c-c"` aliases, and everything else -- including any other letter --
    /// falls through to `config/keybinds.rs`'s `parse_key_combo`, which
    /// splits strictly on `+` and matches modifier tokens by exact string
    /// (`"ctrl"`, `"control"`). A hyphenated `"ctrl-c"` string matches
    /// neither path and comes back `invalid_key` from a real server. This
    /// separator is the verified, actually-functional one.
    private static let controlComboSeparator = "+"

    public var isRenaming = false
    public var isDragLive = false

    private let client: any HerdrCommandClient
    private let paneID: PaneID
    private let debounceNanoseconds: UInt64
    private var pendingText = ""
    private var flushTask: Task<Void, Never>?
    /// Every `send_input` call for this pane chains onto this, so two
    /// flights (e.g. a debounce-triggered flush racing a following
    /// named-key send) can never complete out of order: each `requestRaw`
    /// opens its own socket connection (`HerdrClient`'s connect-per-request
    /// contract), and unlinked Tasks could otherwise resolve in either
    /// order -- the exact class of bug already found and fixed in
    /// `PaneTerminal.loadOlderHistory`.
    private var sendChain: Task<Void, Never>?

    public init(
        client: any HerdrCommandClient,
        paneID: PaneID,
        debounceNanoseconds: UInt64 = 16_000_000
    ) {
        self.client = client
        self.paneID = paneID
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// A lone DEL (0x7F) or BS (0x08) reaching this call is always a
    /// mis-routed Backspace, never real content: live-verified against a
    /// scratch herdr session (zsh, `stty` `erase = ^?`) that `keys:
    /// ["backspace"]` sends 0x7F and erases correctly, while either byte
    /// sent as `text` rides herdr's bracketed-paste wrapping and lands in
    /// the buffer as an unprintable literal, echoing `^?` instead of erasing
    /// -- the exact defect this guards against, independent of why a raw
    /// control byte reached here instead of the named-key path.
    private static let backspaceControlBytes: Set<Character> = ["\u{7f}", "\u{08}"]

    /// Appends one plain character (or short string -- e.g. an
    /// IME-composed grapheme) to the pending batch and (re)starts the
    /// debounce. A no-op while renaming or a drag is live.
    public func typeCharacter(_ text: String) {
        guard !isRenaming, !isDragLive, !text.isEmpty else { return }
        if text.count == 1, let only = text.first, Self.backspaceControlBytes.contains(only) {
            sendKey(.backspace)
            return
        }
        pendingText += text
        scheduleFlush()
    }

    /// Flushes any pending text immediately, THEN sends the named key --
    /// two separate `send_input` calls, always in that order.
    public func sendKey(_ key: InputKey) {
        guard !isRenaming, !isDragLive else { return }
        cancelFlush()
        let text = drainPendingText()
        let client = self.client
        let paneID = self.paneID
        enqueueSend {
            if !text.isEmpty { await Self.sendText(text, pane: paneID, client: client) }
            await Self.sendKeys([key.rawValue], pane: paneID, client: client)
        }
    }

    /// `character` is the UNMODIFIED key (SwiftUI's `KeyPress.key.character`
    /// with Control held reports the base letter, not a control code),
    /// lowercased into the verified `"ctrl+<char>"` wire form.
    public func sendControlCombo(_ character: Character) {
        guard !isRenaming, !isDragLive else { return }
        cancelFlush()
        let text = drainPendingText()
        let combo = "ctrl\(Self.controlComboSeparator)\(String(character).lowercased())"
        let client = self.client
        let paneID = self.paneID
        enqueueSend {
            if !text.isEmpty { await Self.sendText(text, pane: paneID, client: client) }
            await Self.sendKeys([combo], pane: paneID, client: client)
        }
    }

    private func scheduleFlush() {
        cancelFlush()
        flushTask = Task { @MainActor [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingText()
        }
    }

    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    private func flushPendingText() {
        let text = drainPendingText()
        guard !text.isEmpty else { return }
        let client = self.client
        let paneID = self.paneID
        enqueueSend { await Self.sendText(text, pane: paneID, client: client) }
    }

    private func drainPendingText() -> String {
        defer { pendingText = "" }
        return pendingText
    }

    private func enqueueSend(_ operation: @escaping @Sendable () async -> Void) {
        let previous = sendChain
        sendChain = Task {
            _ = await previous?.value
            await operation()
        }
    }

    private static func sendText(_ text: String, pane: PaneID, client: any HerdrCommandClient) async {
        _ = try? await client.requestRaw(
            "pane.send_input", ["pane_id": .string(pane.rawValue), "text": .string(text)]
        )
    }

    private static func sendKeys(_ keys: [String], pane: PaneID, client: any HerdrCommandClient) async {
        _ = try? await client.requestRaw(
            "pane.send_input", ["pane_id": .string(pane.rawValue), "keys": .array(keys.map { .string($0) })]
        )
    }
}

/// Tracks per-pane provenance and activity for the new-pane harness launcher
/// overlay: pristine only for a pane paddock itself created this session,
/// until the first keystroke routed through it or the first screen output
/// beyond the bare prompt row(s) -- whichever comes first, permanently
/// thereafter (neither set is ever pruned). A pane never registered via
/// `registerPaddockCreated` -- i.e. one herdr itself created -- is never
/// pristine.
@MainActor
public final class PaneLauncherRegistry {
    private var createdByPaddock: Set<PaneID> = []
    private var hiddenPermanently: Set<PaneID> = []

    public init() {}

    /// Called with the pane id a `pane.split`/`tab.create`/`workspace.create`
    /// response just handed back -- the provenance seam.
    public func registerPaddockCreated(_ pane: PaneID) {
        createdByPaddock.insert(pane)
    }

    public func recordKeystroke(_ pane: PaneID) {
        hiddenPermanently.insert(pane)
    }

    /// `nonEmptyRowCount` is the `screenText()` heuristic: a bare prompt is
    /// at most 2 non-empty rows (the shell line and the prompt line);
    /// anything beyond that means real output has appeared.
    public func recordScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int) {
        guard nonEmptyRowCount > 2 else { return }
        hiddenPermanently.insert(pane)
    }

    public func isPristine(_ pane: PaneID) -> Bool {
        createdByPaddock.contains(pane) && !hiddenPermanently.contains(pane)
    }
}
