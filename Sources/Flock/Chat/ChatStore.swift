import FlockCore
import Foundation
import Observation

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

    @ObservationIgnored private var runner: ChatRunning?
    private let toasts: ToastCenter
    private var statuses: [PaneID: ChatStatus] = [:]
    /// Populated by `peek()`, keyed by each buddy's own pane.
    private var unreadCounts: [PaneID: Int] = [:]
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
        makeRunner: @escaping (String) -> ChatRunning = { ChatRunner(binaryPath: $0) }
    ) {
        self.toasts = toasts
        startProbe(probe: probe, makeRunner: makeRunner)
    }

    private func startProbe(
        probe: @escaping () async -> String?, makeRunner: @escaping (String) -> ChatRunning
    ) {
        probeTask = Task { [weak self] in
            guard let path = await probe(), let self else { return }
            self.runner = makeRunner(path)
            self.isAvailable = true
        }
    }

    func status(for pane: PaneID) -> ChatStatus? {
        statuses[pane]
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
    /// faster, newer one that already landed for the same pane.
    private func applyStatus(from verb: ChatVerb, pane: PaneID) async {
        let generation = (requestGenerations[pane] ?? 0) + 1
        requestGenerations[pane] = generation
        guard let status: ChatStatus = await run(verb) else { return }
        guard requestGenerations[pane] == generation else { return }
        statuses[pane] = status
    }

    private func run<T: Decodable>(_ verb: ChatVerb) async -> T? {
        guard isAvailable, let runner else { return nil }
        do {
            let (stdout, exitCode) = try await runner.run(verb)
            return try ChatOutcome.decode(T.self, stdout: stdout, exitCode: exitCode)
        } catch is CancellationError {
            // A popover's `.task` cancels on teardown; that is not a failure
            // the user asked about, so it must never surface as a toast.
            return nil
        } catch {
            toasts.show((error as? ChatFailure)?.message ?? "chat failed", kind: .info)
            return nil
        }
    }
}
