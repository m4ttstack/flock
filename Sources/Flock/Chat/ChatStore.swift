import FlockCore
import Foundation
import Observation

/// The one thing every chat view reads and drives: whether chat exists on
/// this machine, each pane's cached sign-in status, and every headless verb,
/// each landing as a toast on failure rather than a thrown error a view would
/// have to catch.
///
/// Injected via the SwiftUI environment (`.environment(chatStore)`), mirroring
/// `ThemeStore`/`TerminalTextSizeStore`: the runner is a constructor parameter
/// so a test passes a fake instead of spawning the real binary.
@MainActor
@Observable
final class ChatStore {
    /// `ChatToolLocator.binaryPath != nil` and nothing else -- no verb below
    /// runs while this is false, which is the whole difference between chat
    /// being absent and chat being broken.
    let isAvailable: Bool

    private let runner: ChatRunning
    private let toasts: ToastCenter
    private var statuses: [PaneID: ChatStatus] = [:]

    init(runner: ChatRunning, toasts: ToastCenter, binaryPath: String? = ChatToolLocator.binaryPath) {
        self.runner = runner
        self.toasts = toasts
        isAvailable = binaryPath != nil
    }

    func status(for pane: PaneID) -> ChatStatus? {
        statuses[pane]
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

    func peek() async -> ChatPeek? {
        await run(.peek)
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
    /// call would, so all three verbs update the cache identically.
    private func applyStatus(from verb: ChatVerb, pane: PaneID) async {
        guard let status: ChatStatus = await run(verb) else { return }
        statuses[pane] = status
    }

    private func run<T: Decodable>(_ verb: ChatVerb) async -> T? {
        guard isAvailable else { return nil }
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
