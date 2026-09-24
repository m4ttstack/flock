import Foundation

extension RtCoordinator {
    enum Closing: Sendable {
        case tabs([TabID])
        case workspace(WorkspaceID)
    }

    public func shutDown(_ id: String) async {
        if let running = shutdowns[id] {
            await running.value
            return
        }
        defer { reaping.remove(id) }
        guard let item = items[id] else { return }
        watches.removeValue(forKey: id)?.cancel()
        items[id]?.isRunning = false
        let targets = item.kind == .runner ? [item.firstPaneID] : panes(of: item)
        let closing: Closing = item.kind == .runner ? .workspace(item.workspaceID) : .tabs([item.tabID])
        let task = Task { [weak self] in
            await self?.stop(targets)
            self?.forget(id)
            await self?.close(closing)
        }
        shutdowns[id] = task
        await task.value
        shutdowns[id] = nil
    }

    /// `ctrl+c`, then `y` only where rt's own UI is still up a second later:
    /// that is a confirm (a board with services running), and a `y` sent
    /// anywhere else could answer some other program's prompt. SIGHUP from the
    /// close that follows is the backstop.
    func stop(_ panes: [PaneID]) async {
        for pane in panes {
            if await herdr.paneState(pane)?.busy == true {
                try? await herdr.sendKeys(["ctrl+c"], to: pane)
            }
        }
        try? await Task.sleep(for: config.confirmDelay)
        for pane in panes {
            if await herdr.paneState(pane)?.foregroundNames.contains("rt-ui") == true {
                try? await herdr.sendKeys(["y"], to: pane)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: config.shutdownTimeout)
        while ContinuousClock.now < deadline {
            var busy = false
            for pane in panes where !busy {
                if await herdr.paneState(pane)?.busy == true { busy = true }
            }
            if !busy { return }
            try? await Task.sleep(for: config.pollInterval)
        }
    }

    func close(_ closing: Closing) async {
        switch closing {
        case .tabs(let tabs):
            for tab in tabs {
                try? await herdr.closeTab(tab)
            }
        case .workspace(let workspace):
            try? await herdr.closeWorkspace(workspace)
        }
    }

    func panes(inTab tab: TabID, of model: SessionModel) -> [PaneID] {
        model.panes.values.filter { $0.tabID == tab }.map(\.paneID).sorted { $0.rawValue < $1.rawValue }
    }

    func isFlockOwned(_ workspace: WorkspaceID, in model: SessionModel) -> Bool {
        model.workspaces.first { $0.workspaceID == workspace }.map { RtLabels.isFlockOwned(workspaceLabel: $0.label) } ?? false
    }

    func pane(for terminal: TerminalID, in model: SessionModel) -> PaneRecord? {
        model.panes.values.first { $0.terminalID == terminal && !isFlockOwned($0.workspaceID, in: model) }
    }

    /// The full model, flock-owned workspaces included. Called on every model
    /// change; a nil model is a gap in the connection and changes nothing.
    public func update(model newModel: SessionModel?) {
        guard let newModel else { return }
        model = newModel
        seenTabs.formUnion(newModel.tabs.values.flatMap { $0 }.map(\.tabID))
        if !adopted, opensInFlight == 0, let present = linkedTerminals(in: newModel) {
            adopted = true
            adopt(newModel, present: present)
        }
        claimStrayTabs(newModel)
        reapGoneLinks(newModel)
        dropClosedTabs(newModel)
        followFocus(newModel)
    }

    /// Terminals of every pane outside flock's own workspaces, or nil when any
    /// of those panes came without one: links cannot be judged then, so
    /// nothing is reaped or adopted.
    func linkedTerminals(in model: SessionModel) -> Set<TerminalID>? {
        var terminals = Set<TerminalID>()
        for pane in model.panes.values where !isFlockOwned(pane.workspaceID, in: model) {
            guard let terminal = pane.terminalID else { return nil }
            terminals.insert(terminal)
        }
        return terminals
    }

    /// Something flock owns but will not keep: stopped cleanly, closed, and
    /// its files deleted when its label named a token.
    func orphan(_ closing: Closing, panes: [PaneID], token: String? = nil) {
        if case .tabs(let tabs) = closing { handledStrays.formUnion(tabs) }
        background { [weak self] in
            await self?.stop(panes)
            await self?.close(closing)
            if let self, let token {
                let paths = RtFilePaths(token: token, directory: self.config.fileDirectory)
                self.files.delete(paths.out)
                self.files.delete(paths.status)
                self.files.delete(paths.seed)
            }
        }
    }

    // MARK: - launch

    private func adopt(_ model: SessionModel, present: Set<TerminalID>) {
        for workspace in model.workspaces where RtLabels.isFlockOwned(workspaceLabel: workspace.label) {
            let tabs = (model.tabs[workspace.workspaceID] ?? []).sorted { $0.number < $1.number }
            if workspace.label == RtLabels.sharedWorkspace {
                for tab in tabs {
                    adoptSharedTab(tab, model: model, present: present)
                }
            } else {
                adoptRunner(workspace, board: tabs.first, model: model, present: present)
            }
        }
    }

    private func adoptRunner(_ workspace: WorkspaceRecord, board: TabRecord?, model: SessionModel, present: Set<TerminalID>) {
        if let label = board?.label, let token = RtLabels.tabLink(fromLabel: label)?.token, items[token] != nil { return }
        let boardPanes = board.map { panes(inTab: $0.tabID, of: model) } ?? []
        guard let board, let link = RtLabels.tabLink(fromLabel: board.label), link.kind == .runner,
              present.contains(link.terminal), let first = boardPanes.first,
              files.read(RtFilePaths(token: link.token, directory: config.fileDirectory).status) == nil
        else {
            orphan(.workspace(workspace.workspaceID), panes: boardPanes, token: board.flatMap { RtLabels.tabLink(fromLabel: $0.label)?.token })
            return
        }
        items[link.token] = RtItem(
            id: link.token, kind: .runner, linked: link.terminal, workspaceID: workspace.workspaceID,
            tabID: board.tabID, firstPaneID: first, title: RtKind.runner.defaultTitle,
            folder: model.panes[first]?.cwd ?? "", isRunning: true, started: true, strip: nil
        )
        lifecycles[link.token] = RtLifecycle(kind: .runner, startedAt: now())
        openedOrder.append(link.token)
        startWatch(link.token)
    }

    /// nav and glitter only exist inside a modal, and there is none after a
    /// restart, so only rt runs are adopted. The files say which phase one is in.
    private func adoptSharedTab(_ tab: TabRecord, model: SessionModel, present: Set<TerminalID>) {
        // Already known: opened before the first model arrived.
        if let token = RtLabels.tabLink(fromLabel: tab.label)?.token, items[token] != nil { return }
        let tabPanes = panes(inTab: tab.tabID, of: model)
        guard let link = RtLabels.tabLink(fromLabel: tab.label), link.kind == .run,
              present.contains(link.terminal), let first = tabPanes.first
        else {
            orphan(.tabs([tab.tabID]), panes: tabPanes, token: RtLabels.tabLink(fromLabel: tab.label)?.token)
            return
        }
        let paths = RtFilePaths(token: link.token, directory: config.fileDirectory)
        let statusText = RtFileParse.writtenStatus(files.read(paths.status))
        let result = RtFileParse.runResult(files.read(paths.out))
        let stage: RtLifecycle.Stage
        var strip: RtStrip?
        switch (result, statusText) {
        case (.some, .some):
            stage = .done
            strip = .finished(RtFileParse.status(statusText))
        case (.some, .none):
            stage = .script
        case (.none, .none):
            stage = .picking
        case (.none, .some):
            guard RtFileParse.status(statusText) == 0 else {
                orphan(.tabs([tab.tabID]), panes: tabPanes, token: link.token)
                return
            }
            stage = .selfLaunched
        }
        items[link.token] = RtItem(
            id: link.token, kind: .run, linked: link.terminal, workspaceID: tab.workspaceID, tabID: tab.tabID,
            firstPaneID: first, title: result?.commandTemplate ?? RtKind.run.defaultTitle,
            folder: model.panes[first]?.cwd ?? "", isRunning: stage != .done, started: true, strip: strip
        )
        lifecycles[link.token] = RtLifecycle.resumed(kind: .run, stage: stage, at: now())
        openedOrder.append(link.token)
        if stage != .done { startWatch(link.token) }
    }

    // MARK: - every update

    /// A tab in `flock:rt` with no link is none of flock's: every item is one
    /// tab flock opened and labelled. Skipped while an open is in flight: a
    /// workspace's first tab is unlabelled until its rename lands.
    private func claimStrayTabs(_ model: SessionModel) {
        guard opensInFlight == 0 else { return }
        let owned = Set(items.values.map(\.tabID))
        for workspace in model.workspaces where workspace.label == RtLabels.sharedWorkspace {
            for tab in model.tabs[workspace.workspaceID] ?? [] {
                guard RtLabels.tabLink(fromLabel: tab.label) == nil, !owned.contains(tab.tabID),
                      !handledStrays.contains(tab.tabID) else { continue }
                orphan(.tabs([tab.tabID]), panes: panes(inTab: tab.tabID, of: model))
            }
        }
    }

    private func reapGoneLinks(_ model: SessionModel) {
        guard let present = linkedTerminals(in: model) else { return }
        for item in items.values where !present.contains(item.linked) && !reaping.contains(item.id) {
            reaping.insert(item.id)
            let id = item.id
            background { [weak self] in await self?.shutDown(id) }
        }
    }

    /// A tab counts as closed only once it has been seen: the event naming a
    /// new tab can arrive after herdr's answer to the create.
    private func dropClosedTabs(_ model: SessionModel) {
        let live = Set(model.tabs.values.flatMap { $0 }.map(\.tabID))
        for (id, item) in items where shutdowns[id] == nil && !reaping.contains(id) {
            if seenTabs.contains(item.tabID), !live.contains(item.tabID) { forget(id) }
        }
        if let service = modal?.serviceTabID, seenTabs.contains(service), !live.contains(service) {
            modal?.serviceTabID = nil
        }
    }

    /// herdr's focus lands in a flock-owned workspace only from outside flock:
    /// a runner's focus key opening an attach tab, or the herdr TUI. An attach
    /// tab becomes the service view. Either way herdr's focus goes back: to
    /// the pane the item is linked to, or with no owning item, to the last
    /// visible pane herdr had, so the canvas is never left with none.
    private func followFocus(_ model: SessionModel) {
        let focused = model.focusedPaneID
        defer { lastSeenFocus = focused }
        guard let focused, focused != lastSeenFocus, let pane = model.panes[focused] else { return }
        guard isFlockOwned(pane.workspaceID, in: model) else {
            lastVisibleFocus = focused
            return
        }
        let owner = items.values.first {
            $0.workspaceID == pane.workspaceID && ($0.kind == .runner || $0.tabID == pane.tabID)
        }
        if let owner, owner.kind == .runner, pane.tabID != owner.tabID {
            modal = RtModal(itemID: owner.id, tabID: owner.tabID, serviceTabID: pane.tabID)
        }
        let back = owner.flatMap { self.pane(for: $0.linked, in: model)?.paneID }
            ?? lastVisibleFocus.flatMap { model.panes[$0] != nil ? $0 : nil }
        guard let back else { return }
        background { [herdr] in try? await herdr.focus(back) }
    }

    /// Waits out every task this coordinator started in the background,
    /// including any those tasks start in turn.
    public func settle() async {
        while let task = pendingWork.values.first ?? shutdowns.values.first {
            await task.value
            await Task.yield()
        }
    }
}
