import Foundation
import Observation

/// Every rt command flock runs off the canvas: nav, glitter, run and runner,
/// each in a herdr pane flock owns (`RtLabels`), shown in the one modal and
/// linked to the pane it was opened from by that pane's terminal.
///
/// A command's life is `RtLifecycle`'s; this class carries out each outcome
/// over herdr (`RtHerdr`) and the two files the typed line writes
/// (`RtFileStore`). Links, shutdowns and launch adoption are in
/// `RtCoordinator+Lifetime`.
@MainActor
@Observable
public final class RtCoordinator {
    public struct Config: Sendable {
        public var pollInterval: Duration
        public var confirmDelay: Duration
        public var shutdownTimeout: Duration
        /// How long a new pane gets to show its shell at a prompt before a
        /// line is typed into it.
        public var shellWait: Duration
        /// Consecutive unanswered polls before an item is taken as gone. One
        /// dropped answer (a herdr reconnect) must not orphan a live runner.
        public var missLimit: Int
        public var fileDirectory: URL

        public init(
            pollInterval: Duration = .milliseconds(300),
            confirmDelay: Duration = .seconds(1),
            shutdownTimeout: Duration = .seconds(10),
            shellWait: Duration = .seconds(2),
            missLimit: Int = 10,
            fileDirectory: URL = ScratchDirectory.url.appendingPathComponent("rt", isDirectory: true)
        ) {
            self.pollInterval = pollInterval
            self.confirmDelay = confirmDelay
            self.shutdownTimeout = shutdownTimeout
            self.shellWait = shellWait
            self.missLimit = missLimit
            self.fileDirectory = fileDirectory
        }
    }

    public internal(set) var items: [String: RtItem] = [:]
    public internal(set) var modal: RtModal?

    let herdr: RtHerdr
    let files: any RtFileStore
    let config: Config
    let now: @MainActor () -> Date
    let makeToken: @MainActor () -> String
    let notice: @MainActor (String) -> Void

    @ObservationIgnored var lifecycles: [String: RtLifecycle] = [:]
    @ObservationIgnored var watches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var misses: [String: Int] = [:]
    @ObservationIgnored var shutdowns: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var model: SessionModel?
    @ObservationIgnored var openedOrder: [String] = []
    @ObservationIgnored var opensInFlight = 0
    @ObservationIgnored var adopted = false
    @ObservationIgnored var reaping: Set<String> = []
    @ObservationIgnored var seenTabs: Set<TabID> = []
    @ObservationIgnored var handledStrays: Set<TabID> = []
    @ObservationIgnored var lastSeenFocus: PaneID?
    @ObservationIgnored var lastVisibleFocus: PaneID?
    /// Terminals with a runner create in flight, so a second `open(.runner)`
    /// arriving before the first item exists (`runner(linkedTo:)` sees
    /// nothing yet) is turned away rather than starting a second workspace.
    @ObservationIgnored var openingRunners: Set<TerminalID> = []

    public init(
        client: any HerdrCommandClient,
        files: any RtFileStore = DiskRtFileStore(),
        config: Config = Config(),
        now: @escaping @MainActor () -> Date = { Date() },
        makeToken: @escaping @MainActor () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
        notice: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        herdr = RtHerdr(client: client)
        self.files = files
        self.config = config
        self.now = now
        self.makeToken = makeToken
        self.notice = notice
    }

    // MARK: - what the chrome reads

    public var modalItem: RtItem? {
        modal.flatMap { items[$0.itemID] }
    }

    public func runner(linkedTo terminal: TerminalID) -> RtItem? {
        items.values.first { $0.kind == .runner && $0.linked == terminal }
    }

    /// In the order they were opened, so the popover lists them the same way every time.
    public func runItems(linkedTo terminal: TerminalID) -> [RtItem] {
        openedOrder.compactMap { items[$0] }.filter { $0.kind == .run && $0.linked == terminal }
    }

    public func buttonAppearance(linkedTo terminal: TerminalID?, rtInstalled: Bool) -> RtButtonModel.Appearance {
        guard let terminal else { return .absent }
        return RtButtonModel.appearance(
            rtInstalled: rtInstalled,
            runningItems: runItems(linkedTo: terminal).filter(\.isRunning).count,
            hasRunner: runner(linkedTo: terminal) != nil
        )
    }

    public func commandRows(linkedTo terminal: TerminalID) -> [RtCommandRow] {
        RtPopoverModel.commands(hasRunner: runner(linkedTo: terminal) != nil)
    }

    /// In the order they were opened, so the popover lists them the same way every time.
    public func runRows(linkedTo terminal: TerminalID) -> [RtRunRow] {
        runItems(linkedTo: terminal).map(\.runRow)
    }

    // MARK: - opening

    public func open(_ kind: RtKind, from pane: PaneRecord, seed: String? = nil, reveal: Bool = true) async {
        guard let terminal = pane.terminalID else { return }
        if kind == .runner {
            if let existing = runner(linkedTo: terminal) {
                await show(existing.id)
                return
            }
            guard openingRunners.insert(terminal).inserted else { return }
        }
        defer { if kind == .runner { openingRunners.remove(terminal) } }
        opensInFlight += 1
        defer { opensInFlight -= 1 }
        let folder = await folder(of: pane)
        let token = makeToken()
        let paths = RtFilePaths(token: token, directory: config.fileDirectory)
        files.prepareDirectory(config.fileDirectory)
        files.delete(paths.out)
        files.delete(paths.status)
        var env = ["FLOCK_RT_OUT": paths.out.path, "FLOCK_RT_STATUS": paths.status.path]
        if let seed {
            files.write(seed, to: paths.seed)
            env["FLOCK_RT_SEED"] = paths.seed.path
        }
        let label = RtLabels.tabLabel(RtLabels.TabLink(kind: kind, terminal: terminal, token: token))
        var created: RtHerdr.Created?
        var ownsWorkspace = false
        do {
            let host: RtHerdr.Created
            if kind == .runner {
                host = try await herdr.createWorkspace(label: RtLabels.runnerWorkspaceLabel(linkedTo: terminal), cwd: folder, env: env)
                created = host
                ownsWorkspace = true
                try await herdr.renameTab(host.tabID, to: label)
            } else if let shared = sharedWorkspaceID {
                host = try await herdr.createTab(in: shared, label: label, cwd: folder, env: env)
                created = host
            } else {
                host = try await herdr.createWorkspace(label: RtLabels.sharedWorkspace, cwd: folder, env: env)
                created = host
                ownsWorkspace = true
                try await herdr.renameTab(host.tabID, to: label)
            }
            let shell = await waitForShell(host.rootPaneID)
            try await herdr.type(RtCommandLine.command(for: kind, shell: shell, seeded: seed != nil), into: host.rootPaneID)
            items[token] = RtItem(
                id: token, kind: kind, linked: terminal, workspaceID: host.workspaceID, tabID: host.tabID,
                firstPaneID: host.rootPaneID, title: kind.defaultTitle, folder: folder,
                isRunning: true, started: false, strip: nil
            )
            lifecycles[token] = RtLifecycle(kind: kind, startedAt: now())
            openedOrder.append(token)
            if reveal { await show(token) }
            startWatch(token)
        } catch {
            notice("rt \(kind.rawValue) failed: \(RtHerdr.describe(error))")
            if let created {
                if ownsWorkspace {
                    try? await herdr.closeWorkspace(created.workspaceID)
                } else {
                    try? await herdr.closeTab(created.tabID)
                }
            }
            files.delete(paths.out)
            files.delete(paths.status)
            files.delete(paths.seed)
        }
    }

    /// Where the pane is working: an agent its shell launched can be in
    /// another folder than the shell (`pane.cwd`). The folder of the
    /// foreground group's leader, else herdr's record of the foreground's
    /// folder, else the shell's.
    func folder(of pane: PaneRecord) async -> String {
        await herdr.paneState(pane.paneID)?.leaderCwd ?? pane.foregroundCwd ?? pane.cwd
    }

    var sharedWorkspaceID: WorkspaceID? {
        model?.workspaces.first { $0.label == RtLabels.sharedWorkspace }?.workspaceID
    }

    /// Waits, bounded, for the new pane's shell to stand alone in its
    /// foreground and name itself: before that its startup can hold the
    /// foreground (fish running config subprocesses) and a typed line can be
    /// lost. Past the bound, the user's login shell decides the status
    /// variable.
    func waitForShell(_ pane: PaneID) async -> ShellFlavor {
        let deadline = ContinuousClock.now.advanced(by: config.shellWait)
        while ContinuousClock.now < deadline {
            if let state = await herdr.paneState(pane), !state.busy, let name = state.shellName {
                return ShellFlavor(processName: name)
            }
            try? await Task.sleep(for: config.pollInterval)
        }
        let loginShell = ProcessInfo.processInfo.environment["SHELL"].map { URL(fileURLWithPath: $0).lastPathComponent }
        return ShellFlavor(processName: loginShell)
    }

    /// Runs `work` in the background, kept in `pendingWork` only while it runs.
    func background(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingWork[id] = Task { [weak self] in
            await work()
            self?.pendingWork[id] = nil
        }
    }

    // MARK: - the modal

    /// Claims the modal for `id` before any await: an overlapping `show`
    /// reads `modal` next only after this one has already written it, never
    /// during a gap left by the outgoing item's disposal. That disposal runs
    /// in the background (`settle()` waits for it) so this item's watch
    /// starts without waiting on it.
    public func show(_ id: String) async {
        guard let item = items[id] else { return }
        let outgoing = modal
        modal = RtModal(itemID: id, tabID: item.tabID, serviceTabID: nil)
        if let outgoing, outgoing.itemID != id {
            background { [weak self] in
                guard let self else { return }
                if outgoing.serviceTabID != nil, let outgoingItem = self.items[outgoing.itemID] {
                    await self.closeAttachTabs(of: outgoingItem)
                }
                await self.dispose(outgoing.itemID)
            }
        }
    }

    /// nav and glitter exist only inside the modal, so closing one early
    /// shuts it down; an rt run or a runner keeps going, hidden. Anything on
    /// a strip is over, and goes.
    func dispose(_ id: String) async {
        guard let item = items[id] else { return }
        if item.strip != nil {
            await closeItem(id)
        } else {
            switch item.kind {
            case .nav, .glitter: await shutDown(id)
            case .run, .runner: break
            }
        }
    }

    /// A plain close, with nothing else claiming the modal next: herdr's
    /// focus goes to the pane the item belongs to, which the rt button's
    /// click never moved to, before the item is disposed of by `dispose`'s
    /// rules.
    public func closeModal() async {
        guard let current = modal else { return }
        modal = nil
        guard let item = items[current.itemID] else { return }
        // Before the shutdown, which waits out its confirm delay: focus moves
        // with the close, not a second after it.
        await focusLinked(item.linked)
        if current.serviceTabID != nil { await closeAttachTabs(of: item) }
        await dispose(current.itemID)
    }

    func focusLinked(_ terminal: TerminalID) async {
        guard let model, let pane = pane(for: terminal, in: model) else { return }
        try? await herdr.focus(pane.paneID)
    }

    /// Closing an attach tab detaches from the service; the service runs on.
    public func backToBoard() async {
        guard let current = modal, current.serviceTabID != nil, let item = items[current.itemID], item.kind == .runner else { return }
        modal?.serviceTabID = nil
        await closeAttachTabs(of: item)
    }

    /// Every tab in a runner's workspace but its board: the attach tabs herdr
    /// opened for services the runner is showing.
    func closeAttachTabs(of item: RtItem) async {
        let attachTabs = (model?.tabs[item.workspaceID] ?? []).map(\.tabID).filter { $0 != item.tabID }
        for tab in attachTabs {
            try? await herdr.closeTab(tab)
        }
    }

    // MARK: - watching

    /// `self` is taken weakly on every poll, so a coordinator that goes away
    /// ends its watches rather than being kept alive by them.
    func startWatch(_ id: String) {
        watches[id]?.cancel()
        let interval = config.pollInterval
        watches[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard await self.poll(id) else { return }
            }
        }
    }

    /// One poll and whatever its outcome asks for. Whether to keep watching.
    /// A pane closed in herdr is dropped by `update(model:)`; unanswered polls
    /// alone forget an item only once they run to `missLimit`.
    private func poll(_ id: String) async -> Bool {
        guard let item = items[id] else { return false }
        let observation = await observe(item)
        guard !Task.isCancelled else { return false }
        guard let observation else {
            let missed = (misses[id] ?? 0) + 1
            misses[id] = missed
            guard missed >= config.missLimit else { return true }
            forget(id)
            return false
        }
        misses[id] = nil
        if observation.firstPaneBusy, items[id]?.started == false {
            items[id]?.started = true
            items[id]?.startedAt = now()
        }
        guard var lifecycle = lifecycles[id] else { return false }
        let outcome = lifecycle.observe(observation)
        lifecycles[id] = lifecycle
        return await apply(outcome, to: id)
    }

    private func observe(_ item: RtItem) async -> RtLifecycle.Observation? {
        guard let first = await herdr.paneState(item.firstPaneID) else { return nil }
        var anyBusy = first.busy
        for pane in panes(of: item) where pane != item.firstPaneID && !anyBusy {
            if await herdr.paneState(pane)?.busy == true { anyBusy = true }
        }
        let paths = RtFilePaths(token: item.id, directory: config.fileDirectory)
        let statusText = RtFileParse.writtenStatus(files.read(paths.status))
        return RtLifecycle.Observation(
            firstPaneBusy: first.busy, anyPaneBusy: anyBusy, statusExists: statusText != nil,
            status: RtFileParse.status(statusText), out: files.read(paths.out), now: now()
        )
    }

    /// Whether to keep watching.
    private func apply(_ outcome: RtLifecycle.Outcome, to id: String) async -> Bool {
        switch outcome {
        case .watching:
            return true
        case .typePhaseTwo(let result):
            guard let item = items[id] else { return false }
            files.delete(RtFilePaths(token: id, directory: config.fileDirectory).status)
            let shell = ShellFlavor(processName: await herdr.paneState(item.firstPaneID)?.shellName)
            do {
                try await herdr.type(RtCommandLine.phaseTwo(result, shell: shell), into: item.firstPaneID)
            } catch {
                notice("rt run failed: \(RtHerdr.describe(error))")
                await closeItem(id)
                return false
            }
            items[id]?.title = result.commandTemplate
            lifecycles[id]?.phaseTwoTyped(at: now())
            return true
        case .closeTab, .runnerEnded:
            let linked = items[id]?.linked
            let wasShown = modal?.itemID == id
            await closeItem(id)
            if wasShown, let linked { await focusLinked(linked) }
            return false
        case .cdLinkedPane(let path):
            let linked = items[id]?.linked
            await closeItem(id)
            if let linked { await cd(linkedTo: linked, into: path) }
            return false
        case .exited(let status):
            items[id]?.isRunning = false
            items[id]?.started = true
            items[id]?.strip = .exited(status)
            return false
        case .finished(let status):
            items[id]?.isRunning = false
            items[id]?.started = true
            items[id]?.strip = .finished(status)
            return false
        case .becomeRunner(let seed):
            guard let item = items[id] else { return false }
            let wasShown = modal?.itemID == id
            await closeItem(id)
            if let existing = runner(linkedTo: item.linked) {
                notice("A runner is already running for this pane: add scripts from its board.")
                if wasShown { await show(existing.id) }
                return false
            }
            guard let model, let pane = pane(for: item.linked, in: model) else { return false }
            await open(.runner, from: pane, seed: seed, reveal: wasShown)
            return false
        }
    }

    /// A linked pane at its prompt takes the `cd` and the focus; a busy one
    /// (an agent running, or one herdr cannot say) is split at the folder
    /// instead, and the split takes the focus.
    func cd(linkedTo terminal: TerminalID, into path: String) async {
        guard let model, let pane = pane(for: terminal, in: model) else { return }
        do {
            if await herdr.paneState(pane.paneID)?.busy == false {
                try await herdr.type(RtCommandLine.cd(path), into: pane.paneID)
                try await herdr.focus(pane.paneID)
            } else {
                try await herdr.split(pane.paneID, cwd: path)
            }
        } catch {
            notice("cd here failed: \(RtHerdr.describe(error))")
        }
    }

    /// Every pane in the item's tab. A runner's attach tabs are not the
    /// item's own: they are views onto services, never the runner's panes.
    func panes(of item: RtItem) -> [PaneID] {
        guard let model else { return [item.firstPaneID] }
        let found = panes(inTab: item.tabID, of: model)
        return found.isEmpty ? [item.firstPaneID] : found
    }

    // MARK: - ending

    /// herdr no longer answers for the item: only flock's record of it goes.
    func forget(_ id: String) {
        items[id] = nil
        lifecycles[id] = nil
        watches[id] = nil
        misses[id] = nil
        openedOrder.removeAll { $0 == id }
        if modal?.itemID == id { modal = nil }
        let paths = RtFilePaths(token: id, directory: config.fileDirectory)
        files.delete(paths.out)
        files.delete(paths.status)
        files.delete(paths.seed)
    }

    func closeItem(_ id: String) async {
        guard let item = items[id] else { return }
        forget(id)
        if item.kind == .runner {
            try? await herdr.closeWorkspace(item.workspaceID)
        } else {
            try? await herdr.closeTab(item.tabID)
        }
    }
}
