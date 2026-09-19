import FlockCore
import Foundation
import Observation

/// One pane's popover, opened at one of its views: `feature` nil means the
/// status root. What a global chat command hands `ChatStore.requestPopover`,
/// and what that pane's own view reads back to open at the right place
/// rather than always at the root.
struct ChatPopoverRequest: Equatable {
    let pane: PaneID
    let feature: ChatPopoverFeature?
}

/// The one thing every chat view reads and drives: whether chat exists on
/// this machine, each pane's cached sign-in status, and every headless verb,
/// each landing as a toast on failure rather than a thrown error a view would
/// have to catch.
///
/// Injected via the SwiftUI environment (`.environment(chatStore)`), mirroring
/// `ThemeStore`/`TerminalTextSizeStore` for the injection shape: `probe` and
/// `makeRunner` are constructor parameters so a test controls exactly when
/// availability resolves and hands the store a fake instead of a real binary.
@MainActor
@Observable
final class ChatStore {
    /// Starts false and flips true exactly once, from `probeTask` -- never
    /// computed from anything else, so no verb below can disagree with it
    /// about whether chat exists on this machine.
    private(set) var isAvailable = false

    /// Set once from the same probe that resolves `isAvailable`: Open Viewer
    /// alone depends on deck, so its absence names its own reason instead of
    /// pulling the whole feature down.
    private(set) var viewerDisabledReason: String?

    /// Which pane a global chat command (the Chat menu, a keyboard shortcut)
    /// wants its popover opened for, and at which view -- consumed once by
    /// that pane's own view, the same shape `SessionViewModel.renameTarget`
    /// uses to open the rename editor from a shortcut instead of a local
    /// click. A shortcut names an action, so it has to land on that action's
    /// own view rather than a launcher the user still has to navigate.
    private(set) var requestedPopover: ChatPopoverRequest?

    @ObservationIgnored private var runner: ChatRunning?
    private let toasts: ToastCenter
    private var statuses: [PaneID: ChatStatus] = [:]
    /// Populated by `peek()`, keyed by each buddy's own pane.
    private var unreadCounts: [PaneID: Int] = [:]
    /// Set when a status call fails and cleared on its next success: what
    /// the popover's Retry banner reads, kept separate from the toast so the
    /// reason stays on screen after a transient toast has faded.
    private var statusErrors: [PaneID: String] = [:]
    @ObservationIgnored private var requestGenerations: [PaneID: Int] = [:]

    /// Resolves once, off the main actor, then installs the runner built from
    /// that same path and flips `isAvailable`. Exposed only so a test can
    /// await the exact moment this store becomes ready rather than guessing
    /// with a sleep; no production call site ever touches it. Started with a
    /// completed placeholder so every stored property has a value before
    /// `startProbe` -- which captures `self` -- runs; a `let` assigned
    /// directly from init's own closure literal does not compile here, since
    /// the closure captures `self` before this very property counts as set.
    @ObservationIgnored private(set) var probeTask: Task<Void, Never> = Task {}

    /// The launch-time `peek()` fired once availability resolves, tracked
    /// only so a test can await the exact moment it settles instead of
    /// racing its own calls against it; production never awaits this, since
    /// launch must not block on a subprocess. Nil until `startProbe` decides
    /// chat is actually available.
    @ObservationIgnored private(set) var peekTask: Task<Void, Never>?

    /// `probe` runs off the main actor by construction (`ChatToolLocator
    /// .probeBinaryPath`'s own detached task): reading `ChatToolLocator
    /// .binaryPath` here, rather than synchronously at construction, is what
    /// keeps its once-only filesystem walk off the main actor no matter how
    /// soon a view reads `isAvailable` after launch. A probe a test never
    /// resolves leaves `isAvailable` false and `runner` nil forever, which is
    /// exactly the "chat binary not found yet" state, not a bug.
    init(
        toasts: ToastCenter,
        probe: @escaping () async -> String? = ChatToolLocator.probeBinaryPath,
        rtProbe: @escaping () async -> Bool = ChatToolLocator.probeRTBinaryFound,
        deckProbe: @escaping () async -> Bool = ChatToolLocator.probeDeckBinaryFound,
        makeRunner: @escaping (String) -> ChatRunning = { ChatRunner(binaryPath: $0) }
    ) {
        self.toasts = toasts
        startProbe(probe: probe, rtProbe: rtProbe, deckProbe: deckProbe, makeRunner: makeRunner)
    }

    private func startProbe(
        probe: @escaping () async -> String?, rtProbe: @escaping () async -> Bool,
        deckProbe: @escaping () async -> Bool, makeRunner: @escaping (String) -> ChatRunning
    ) {
        probeTask = Task { [weak self] in
            // No chat binary is the whole story already: rt and deck are
            // never checked, and nothing about a machine without the plugin
            // touches the real PATH at all.
            guard let path = await probe() else { return }
            let rtIsFound = await rtProbe()
            let deckIsFound = await deckProbe()
            guard let self else { return }
            self.viewerDisabledReason = ChatDegradation.viewerDisabledReason(deckBinaryFound: deckIsFound)
            guard ChatDegradation.isAvailable(chatBinaryFound: true, rtBinaryFound: rtIsFound) else { return }
            self.runner = makeRunner(path)
            self.isAvailable = true
            // The only launch-time entry for unread: after this, it only
            // ever changes from an explicit peek (Chat Peek, Broadcast), per
            // the spec's no-polling rule -- so a badge can go stale between
            // actions, which is accepted rather than chased with a timer.
            self.peekTask = Task { [weak self] in await self?.peek() }
        }
    }

    func status(for pane: PaneID) -> ChatStatus? {
        statuses[pane]
    }

    /// The one-line reason the popover's Retry banner shows, or nil once a
    /// status call for this pane has last succeeded.
    func statusError(for pane: PaneID) -> String? {
        statusErrors[pane]
    }

    /// A global chat command's request to open this pane's popover, read
    /// once by that pane's own view via `onChange`. `feature` nil opens the
    /// status root (Chat Panel, which IS that root); set, it opens straight
    /// to that feature's own sub-view.
    func requestPopover(for pane: PaneID, feature: ChatPopoverFeature? = nil) {
        requestedPopover = ChatPopoverRequest(pane: pane, feature: feature)
    }

    /// Consumed by the targeted pane once it has acted on the request, so
    /// requesting the same pane again later is still seen as a change.
    func clearPopoverRequest() {
        requestedPopover = nil
    }

    func unreadCount(for pane: PaneID) -> Int {
        unreadCounts[pane] ?? 0
    }

    /// The write half of `unreadCount(for:)`, and `peek()`'s own seam for it.
    func setUnreadCount(_ count: Int, for pane: PaneID) {
        unreadCounts[pane] = count
    }

    func refreshStatus(for pane: PaneID) async {
        await applyStatus(from: .status(pane: pane.rawValue), pane: pane)
    }

    func signIn(_ pane: PaneID) async {
        await applyStatus(from: .signIn(pane: pane.rawValue), pane: pane)
    }

    func signOut(_ pane: PaneID) async {
        await applyStatus(from: .signOut(pane: pane.rawValue), pane: pane)
    }

    /// Peek is where unread enters the app: every buddy it names carries its
    /// own pane's unread count, which lands in `unreadCounts` here so the
    /// pane's own chat button (fed by `unreadCount(for:)`) reflects it
    /// without a second, competing source of truth.
    func peek() async -> ChatPeek? {
        guard let peek: ChatPeek = await run(.peek) else { return nil }
        for buddy in peek.buddies {
            setUnreadCount(buddy.unread, for: PaneID(rawValue: buddy.paneID))
        }
        return peek
    }

    func targets() async -> ChatTargets? {
        await run(.targets)
    }

    /// `ChatSent` carries no `ok` field: a decoded reply means the send
    /// happened, and a thrown `ChatFailure` is the only failure shape.
    func quickSend(to: String, body: String) async -> Bool {
        let sent: ChatSent? = await run(.quickSend(to: to, body: body))
        return sent != nil
    }

    /// Returned exactly as rt answered, refusals included: a partial refusal
    /// is not a call failure, so it is never turned into a toast or a nil
    /// here. Summarizing `results` for the user is the broadcast view's job.
    func broadcast(panes: [String], body: String) async -> ChatBroadcast? {
        await run(.broadcast(panes: panes, body: body))
    }

    func jump(handle: String) async -> ChatJump? {
        await run(.jump(handle: handle))
    }

    func viewerURL(room: String?) async -> URL? {
        guard let viewer: ChatViewer = await run(.openViewer(room: room)) else { return nil }
        return URL(string: viewer.url)
    }

    /// Sign-in and sign-out answer with the same status shape a plain status
    /// call would, so all three verbs update the cache identically -- guarded
    /// by a per-pane generation so a slower, older call can never overwrite a
    /// faster, newer one that already landed for the same pane. Unlike
    /// `run`, a failure here is kept (`statusErrors`) rather than only
    /// toasted, since the popover's Retry banner has to outlive the toast.
    private func applyStatus(from verb: ChatVerb, pane: PaneID) async {
        let generation = (requestGenerations[pane] ?? 0) + 1
        requestGenerations[pane] = generation
        let outcome: RunOutcome<ChatStatus> = await attempt(verb)
        guard requestGenerations[pane] == generation else { return }
        switch outcome {
        case let .success(status):
            statuses[pane] = status
            statusErrors[pane] = nil
        case let .failure(message):
            statusErrors[pane] = message
            toasts.show(message, kind: .info)
        case .cancelled, .unavailable:
            break
        }
    }

    private enum RunOutcome<T> {
        case success(T)
        case failure(String)
        case cancelled
        case unavailable
    }

    private func run<T: Decodable>(_ verb: ChatVerb) async -> T? {
        let outcome: RunOutcome<T> = await attempt(verb)
        switch outcome {
        case let .success(value):
            return value
        case let .failure(message):
            toasts.show(message, kind: .info)
            return nil
        case .cancelled, .unavailable:
            return nil
        }
    }

    /// The one gate every verb passes through before anything is spawned
    /// (`ChatDegradation.shouldRunVerb`), and the one place a thrown failure
    /// becomes a plain message rather than an error type callers must catch.
    private func attempt<T: Decodable>(_ verb: ChatVerb) async -> RunOutcome<T> {
        guard ChatDegradation.shouldRunVerb(isAvailable: isAvailable), let runner else { return .unavailable }
        do {
            let (stdout, exitCode) = try await runner.run(verb)
            return .success(try ChatOutcome.decode(T.self, stdout: stdout, exitCode: exitCode))
        } catch is CancellationError {
            // A popover's `.task` cancels on teardown; that is not a failure
            // the user asked about, so it must never surface as a toast.
            return .cancelled
        } catch {
            return .failure((error as? ChatFailure)?.message ?? "chat failed")
        }
    }
}
