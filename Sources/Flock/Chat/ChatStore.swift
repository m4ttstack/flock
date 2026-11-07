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

/// A background agent this Flock started for a Slack chat. `name` stays nil
/// until rt lists the chat. A relaunch restarts the wait for it to open.
struct ChatSlackAgentChat: Equatable, Codable {
    let pane: String
    let repoName: String
    var name: String?
    var startedAt: ContinuousClock.Instant = .now
    var timedOut = false
    var missedTicks = 0

    private enum CodingKeys: String, CodingKey { case pane, repoName, name }
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
    private var faces: [String: ChatFaceImage] = [:]
    @ObservationIgnored private var faceLoads: [String: Task<ChatFaceLoad, Never>] = [:]
    /// Set while rt has no avatar verb, so one ask covers every handle.
    @ObservationIgnored private var faceVerbMissingSince: ContinuousClock.Instant?
    /// Until rt has answered with its verb, one handle at a time asks.
    @ObservationIgnored private var faceVerbWorks = false
    @ObservationIgnored private var faceVerbProbe: Task<ChatFaceLoad, Never>?
    @ObservationIgnored private let loadFace: (@Sendable (_ handle: String) async -> ChatFaceLoad)?
    private let toasts: ToastCenter
    private var statuses: [PaneID: ChatStatus] = [:]
    /// Populated by `peek()`, keyed by each buddy's own pane.
    private var unreadCounts: [PaneID: Int] = [:]
    /// Everyone signed in as of the last peek, keyed by their own pane.
    private(set) var buddies: [PaneID: ChatBuddy] = [:]
    /// Set when a status call fails and cleared on its next success: what
    /// the popover's Retry banner reads, kept separate from the toast so the
    /// reason stays on screen after a transient toast has faded.
    private var statusErrors: [PaneID: String] = [:]
    private var slackTransitions: [PaneID: ChatSlackTransition] = [:]
    /// Keyed by the pane each was started from. Saved, because a chat outlives
    /// the app and only Flock knows which pane it belongs to.
    private var slackAgents: [PaneID: ChatSlackAgentChat] = [:] {
        didSet { saveSlackAgents() }
    }
    @ObservationIgnored private var slackWatches: [PaneID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestGenerations: [PaneID: Int] = [:]
    @ObservationIgnored private let autoSignInIsOn: (String) async -> Bool
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let typeIntoPane: @Sendable (_ pane: String, _ line: String) async -> String?
    @ObservationIgnored private let startAgent: @Sendable (_ repo: String) async -> String?
    @ObservationIgnored private let typeIntoAgent: @Sendable (_ pane: String, _ line: String) async -> String?
    @ObservationIgnored private let readAgentRefusal: @Sendable (_ pane: String) async -> String?
    @ObservationIgnored private let agentIsGone: @Sendable (_ pane: String) async -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    /// A pane drawn in more than one place asks once, not once per view.
    @ObservationIgnored private var followingAutoSignIn: Set<PaneID> = []

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
        makeRunner: @escaping (String) -> ChatRunning = { ChatRunner(binaryPath: $0) },
        autoSignInIsOn: @escaping (String) async -> Bool = ChatToolLocator.autoSignInIsOn(folder:),
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        typeIntoPane: @escaping @Sendable (_ pane: String, _ line: String) async -> String? = ChatToolLocator.typeIntoPane,
        startAgent: @escaping @Sendable (_ repo: String) async -> String? = ChatToolLocator.startSlackAgent,
        typeIntoAgent: @escaping @Sendable (_ pane: String, _ line: String) async -> String? = ChatToolLocator.typeIntoAgent,
        readAgentRefusal: @escaping @Sendable (_ pane: String) async -> String? = ChatToolLocator.slackAgentRefusal(pane:),
        agentIsGone: @escaping @Sendable (_ pane: String) async -> Bool = ChatToolLocator.slackAgentIsGone(pane:),
        loadFace: (@Sendable (_ handle: String) async -> ChatFaceLoad)? = nil,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        defaults: UserDefaults = .standard
    ) {
        self.toasts = toasts
        self.autoSignInIsOn = autoSignInIsOn
        self.pause = pause
        self.typeIntoPane = typeIntoPane
        self.startAgent = startAgent
        self.typeIntoAgent = typeIntoAgent
        self.readAgentRefusal = readAgentRefusal
        self.loadFace = loadFace
        self.agentIsGone = agentIsGone
        self.defaults = defaults
        self.now = now
        slackAgents = Self.savedSlackAgents(in: defaults)
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
            guard let self, !Task.isCancelled else { return }
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

    /// For a session being torn down: a probe or peek still running must not
    /// land in a store nothing shows any more.
    func stop() {
        probeTask.cancel()
        peekTask?.cancel()
        slackWatches.values.forEach { $0.cancel() }
    }

    func status(for pane: PaneID) -> ChatStatus? {
        statuses[pane]
    }

    /// The one-line reason the popover's Retry banner shows, or nil once a
    /// status call for this pane has last succeeded.
    func statusError(for pane: PaneID) -> String? {
        statusErrors[pane]
    }

    func face(for handle: String) -> ChatFaceImage? {
        faces[handle]
    }

    /// Keeps asking until the face is final: a failure may be an rt that has
    /// not got faces yet, and a Slack handle's photo can arrive late. Every
    /// chip showing the handle follows it for itself, so one going away never
    /// strands another; chips asking at once share one rt call.
    func followFace(_ handle: String) async {
        guard let loadFace else { return }
        var attempt = 0
        while !Task.isCancelled, faces[handle]?.isFinal != true {
            if !faceVerbWorks, let probe = faceVerbProbe { _ = await probe.value }
            if faceVerbMissingSince.map({ .now - $0 >= Self.faceVerbRecheck }) ?? true {
                await askFace(handle, loadFace)
            }
            if faces[handle]?.isFinal == true { return }
            let wait = Self.faceRechecks[min(attempt, Self.faceRechecks.count - 1)]
            attempt += 1
            guard (try? await pause(wait)) != nil else { return }
        }
    }

    /// The answer is recorded inside the probe, so a follow waiting on it
    /// wakes to the verb's state already settled.
    private func askFace(_ handle: String, _ loadFace: @escaping @Sendable (String) async -> ChatFaceLoad) async {
        guard !faceVerbWorks else {
            record(await sharedFaceLoad(handle, loadFace), for: handle)
            return
        }
        let probe = Task {
            let answer = await sharedFaceLoad(handle, loadFace)
            record(answer, for: handle)
            return answer
        }
        faceVerbProbe = probe
        _ = await probe.value
        if faceVerbProbe == probe { faceVerbProbe = nil }
    }

    private func record(_ answer: ChatFaceLoad, for handle: String) {
        switch answer {
        case let .face(face):
            faceVerbWorks = true
            faceVerbMissingSince = nil
            faces[handle] = face
        case .noFace:
            faceVerbWorks = true
            faceVerbMissingSince = nil
        case .noVerb:
            faceVerbWorks = false
            faceVerbMissingSince = .now
        }
    }

    private func sharedFaceLoad(
        _ handle: String, _ loadFace: @escaping @Sendable (String) async -> ChatFaceLoad
    ) async -> ChatFaceLoad {
        if let running = faceLoads[handle] { return await running.value }
        let load = Task { await loadFace(handle) }
        faceLoads[handle] = load
        let face = await load.value
        faceLoads[handle] = nil
        return face
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

    /// The menu and palette read a cached status, and a chat started by hand
    /// in the pane is not in it, so this asks again before acting.
    func signOut(_ pane: PaneID) async {
        await applyStatus(from: .status(pane: pane.rawValue), pane: pane, quietly: true)
        guard !signOutIsBlocked(for: pane) else {
            toasts.show("End the Slack chat first", kind: .info)
            return
        }
        await applyStatus(from: .signOut(pane: pane.rawValue), pane: pane)
    }

    /// A background agent's chat outlives this pane's sign-in, so only a chat
    /// held by the pane itself can block it.
    func signOutIsBlocked(for pane: PaneID) -> Bool {
        ChatSlackRow.resolve(status: statuses[pane], transition: slackTransitions[pane])?.blocksSignOut ?? false
    }

    func slackRow(for pane: PaneID) -> ChatSlackRow? {
        guard let agent = slackAgents[pane] else {
            return ChatSlackRow.resolve(status: statuses[pane], transition: slackTransitions[pane])
        }
        guard let name = agent.name else { return .opening }
        return slackTransitions[pane] == .closing ? .closing(name: name) : .open(name: name)
    }

    func slackTransition(for pane: PaneID) -> ChatSlackTransition? {
        slackTransitions[slackOwner(ofAgent: pane.rawValue) ?? pane]
    }

    /// The pane a background agent's chat was started from.
    func slackOwner(ofAgent pane: String) -> PaneID? {
        slackAgents.first { $0.value.pane == pane }?.key
    }

    func slackRepoName(ofAgent pane: String) -> String? {
        slackAgents.values.first { $0.pane == pane }?.repoName
    }

    /// Only so a test can await a wait settling, the way `peekTask` exists.
    func slackWatch(for pane: PaneID) -> Task<Void, Never>? {
        slackWatches[pane]
    }

    /// Nil when Slack is not connected or the list could not be read: the
    /// form then takes a typed name, so neither case is worth a toast.
    func slackPeople() async -> [ChatSlackPerson]? {
        guard case let .success(reply) = await attempt(.slackPeople) as RunOutcome<ChatSlackPeople> else { return nil }
        return reply.people
    }

    /// True once the line is in a new background agent. That says nothing
    /// about the chat: `noteSlackChats` hears about that from rt.
    func startSlackChat(_ pane: PaneID, person: String, problem: String, repo: ChatSlackRepo) async -> Bool {
        guard isAvailable, let line = ChatSlackCommand.line(person: person, problem: problem) else { return false }
        slackTransitions[pane] = .opening
        guard let agent = await startAgent(repo.path) else {
            slackTransitions[pane] = nil
            toasts.show("Slack chat not started: no agent", kind: .info)
            return false
        }
        if let refusal = await typeIntoAgent(agent, line) {
            slackTransitions[pane] = nil
            toasts.show("Slack chat not started: \(refusal)", kind: .info)
            exitAgent(agent, after: .zero)
            return false
        }
        slackAgents[pane] = ChatSlackAgentChat(pane: agent, repoName: repo.name, name: nil, startedAt: now())
        return true
    }

    /// rt's list is the only word on a background agent's chat, and the
    /// agent's screen the only word on why one never opened.
    func noteSlackChats(_ open: [ChatSidebarChat]) async {
        for (owner, agent) in slackAgents {
            if let chat = open.first(where: { $0.pane == agent.pane }) {
                if agent.name != chat.shownName { slackAgents[owner]?.name = chat.shownName }
                if agent.timedOut { slackAgents[owner]?.timedOut = false }
                if slackTransitions[owner] == .opening { slackTransitions[owner] = nil }
            } else if agent.name != nil {
                retire(owner, agent, after: ChatSlackAgent.exitDelay)
            } else if let refusal = await readAgentRefusal(agent.pane) {
                guard slackAgents[owner] == agent else { continue }
                retire(owner, agent, after: .zero)
                toasts.show("Slack chat not started: \(refusal)", kind: .info)
            } else if !agent.timedOut, now() - agent.startedAt > ChatSlackAgent.openDeadline {
                slackAgents[owner]?.timedOut = true
                toasts.show("Slack chat didn't open", kind: .info)
            } else if agent.timedOut {
                let gone = await agentIsGone(agent.pane)
                guard slackAgents[owner] == agent else { continue }
                if !gone {
                    if agent.missedTicks != 0 { slackAgents[owner]?.missedTicks = 0 }
                } else if agent.missedTicks + 1 >= Self.missedTicksToRetire {
                    retire(owner, agent, exit: false)
                } else {
                    slackAgents[owner]?.missedTicks = agent.missedTicks + 1
                }
            }
        }
    }

    private func retire(_ owner: PaneID, _ agent: ChatSlackAgentChat, after delay: Duration = .zero, exit: Bool = true) {
        slackWatches[owner]?.cancel()
        slackAgents[owner] = nil
        slackTransitions[owner] = nil
        if exit { exitAgent(agent.pane, after: delay) }
    }

    private static let faceRechecks: [Duration] = [.seconds(10), .seconds(30), .seconds(120), .seconds(300)]
    /// Just under the last recheck, so whichever follow wakes first asks again.
    private static let faceVerbRecheck: Duration = .seconds(290)
    /// The daemon's pane list silently omits background panes when their server is down.
    private static let missedTicksToRetire = 2
    private static let slackAgentsKey = "chat.slackAgents"

    private static func savedSlackAgents(in defaults: UserDefaults) -> [PaneID: ChatSlackAgentChat] {
        guard let data = defaults.data(forKey: slackAgentsKey),
              let saved = try? JSONDecoder().decode([String: ChatSlackAgentChat].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.map { (PaneID(rawValue: $0.key), $0.value) })
    }

    private func saveSlackAgents() {
        let saved = Dictionary(uniqueKeysWithValues: slackAgents.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.slackAgentsKey)
    }

    private func exitAgent(_ pane: String, after delay: Duration) {
        Task { [pause, typeIntoPane] in
            try? await pause(delay)
            _ = await typeIntoPane(pane, ChatSlackAgent.exitLine)
        }
    }

    func endSlackChat(_ pane: PaneID) async {
        let owner = slackOwner(ofAgent: pane.rawValue) ?? pane
        if let agent = slackAgents[owner] {
            slackTransitions[owner] = .closing
            let closed: ChatSlackClosed? = await run(.slackClose(pane: agent.pane))
            guard closed != nil else {
                slackTransitions[owner] = nil
                return
            }
            watchAgentClose(owner, agent: agent.pane)
            return
        }
        slackTransitions[pane] = .closing
        let closed: ChatSlackClosed? = await run(.slackClose(pane: pane.rawValue))
        guard closed != nil else {
            slackTransitions[pane] = nil
            return
        }
        watchSlack(
            pane, transition: .closing, interval: ChatSlackWatch.closeInterval, attempts: ChatSlackWatch.closeAttempts
        )
    }

    /// rt's list ends the wait through `noteSlackChats`. A chat it keeps
    /// listing would otherwise leave End chat disabled until a relaunch.
    private func watchAgentClose(_ owner: PaneID, agent: String) {
        slackWatches[owner]?.cancel()
        slackWatches[owner] = Task { [weak self, pause] in
            do { try await pause(ChatSlackWatch.closeInterval * ChatSlackWatch.closeAttempts) } catch { return }
            guard let self, self.slackAgents[owner]?.pane == agent, self.slackTransitions[owner] == .closing else { return }
            self.slackTransitions[owner] = nil
            self.toasts.show("Slack chat still open. Check the pane", kind: .info)
        }
    }

    private func watchSlack(_ pane: PaneID, transition: ChatSlackTransition, interval: Duration, attempts: Int) {
        slackWatches[pane]?.cancel()
        slackTransitions[pane] = transition
        slackWatches[pane] = Task { [weak self] in
            await self?.followSlack(pane, transition: transition, interval: interval, attempts: attempts)
        }
    }

    private func followSlack(_ pane: PaneID, transition: ChatSlackTransition, interval: Duration, attempts: Int) async {
        for _ in 0..<attempts {
            await applyStatus(from: .status(pane: pane.rawValue), pane: pane, quietly: true)
            if Task.isCancelled { return }
            if slackWatchIsDone(pane, transition: transition) {
                slackTransitions[pane] = nil
                return
            }
            do { try await pause(interval) } catch { return }
        }
        slackTransitions[pane] = nil
        toasts.show(
            transition == .opening ? "No Slack chat yet. Check the pane" : "Slack chat still open. Check the pane", kind: .info
        )
    }

    private func slackWatchIsDone(_ pane: PaneID, transition: ChatSlackTransition) -> Bool {
        switch statuses[pane]?.slack {
        case .open: transition == .opening
        case .noChat: transition == .closing
        // No key is a lookup that failed, which says nothing about the chat.
        case .unsupported, nil: false
        }
    }

    /// Asks quietly: a session still starting answers with failures the user
    /// never asked about, so none of them toast or reach the Retry banner.
    /// The cached status is never trusted to skip the first ask, since it can
    /// describe an earlier agent in the same pane.
    func followAutoSignIn(_ pane: PaneID, folder: String) async {
        guard isAvailable, !followingAutoSignIn.contains(pane) else { return }
        followingAutoSignIn.insert(pane)
        defer { followingAutoSignIn.remove(pane) }
        guard await autoSignInIsOn(folder) else { return }
        let deadline = ContinuousClock.now + ChatAutoSignIn.window
        for _ in 0..<ChatAutoSignIn.attempts where ContinuousClock.now < deadline {
            do { try await pause(ChatAutoSignIn.interval) } catch { return }
            await applyStatus(from: .status(pane: pane.rawValue), pane: pane, quietly: true)
            if statuses[pane]?.signedIn == true { return }
        }
    }

    /// Peek is where unread enters the app: every buddy it names carries its
    /// own pane's unread count, which lands in `unreadCounts` here so the
    /// pane's own chat button (fed by `unreadCount(for:)`) reflects it
    /// without a second, competing source of truth.
    func peek() async -> ChatPeek? {
        guard let peek: ChatPeek = await run(.peek) else { return nil }
        record(peek)
        return peek
    }

    /// The tab switcher's refresh on every ⌥Tab: a failure keeps the last
    /// list and says nothing, since nobody asked chat anything.
    func refreshBuddies() async {
        guard case let .success(peek) = await attempt(.peek) as RunOutcome<ChatPeek> else { return }
        record(peek)
    }

    private func record(_ peek: ChatPeek) {
        buddies = Dictionary(peek.buddies.map { (PaneID(rawValue: $0.paneID), $0) }, uniquingKeysWith: { first, _ in first })
        for buddy in peek.buddies {
            setUnreadCount(buddy.unread, for: PaneID(rawValue: buddy.paneID))
        }
    }

    func targets(pane: String) async -> ChatTargets? {
        await run(.targets(pane: pane))
    }

    /// `ChatSent` carries no `ok` field: a decoded reply means the send
    /// happened, and a thrown `ChatFailure` is the only failure shape.
    func quickSend(pane: String, to: String, body: String) async -> Bool {
        let sent: ChatSent? = await run(.quickSend(pane: pane, to: to, body: body))
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
    private func applyStatus(from verb: ChatVerb, pane: PaneID, quietly: Bool = false) async {
        let generation = (requestGenerations[pane] ?? 0) + 1
        requestGenerations[pane] = generation
        let outcome: RunOutcome<ChatStatus> = await attempt(verb)
        guard requestGenerations[pane] == generation else { return }
        switch outcome {
        case let .success(status):
            statuses[pane] = status.keepingSlackChat(from: statuses[pane])
            statusErrors[pane] = nil
        case let .failure(message):
            guard !quietly else { return }
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
