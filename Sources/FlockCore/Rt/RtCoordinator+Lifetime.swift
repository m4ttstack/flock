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
        guard let item = items[id] else { return }
        watches.removeValue(forKey: id)?.cancel()
        items[id]?.isRunning = false
        let targets = item.kind == .runner ? [item.firstPaneID] : panes(of: item)
        let closing: Closing = item.kind == .runner ? .workspace(item.workspaceID) : .tabs(item.tabIDs)
        let task = Task { [weak self] in
            await self?.stop(targets)
            self?.forget(id)
            await self?.close(closing)
        }
        shutdowns[id] = task
        await task.value
        shutdowns[id] = nil
        reaping.remove(id)
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

    /// Keeps the full model, which `cd` and the attach tabs read.
    public func update(model newModel: SessionModel?) {
        guard let newModel else { return }
        model = newModel
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
