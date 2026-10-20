import FlockCore
import Foundation
import Observation

/// Everything flock builds for one profile on one herdr server.
/// `ProfileSessionController` replaces it whole on a switch, so nothing
/// app-level may keep a reference to one past `shutdown()`.
@MainActor
@Observable
final class FlockSession: ProfileSession {
    let profile: FlockProfile
    let socketPath: String
    let address: HerdrServerAddress

    var isStartingHerdr = false
    var herdrStartFailure: String?

    let themeStore: ThemeStore
    let terminalTextSizeStore: TerminalTextSizeStore
    let rtModalSizeStore: RtModalSizeStore
    let rtModalTextSizeStore: RtModalTextSizeStore
    let topBarLabelStore: TopBarLabelStore
    let optionAsAltStore: OptionAsAltStore
    let scrollSpeedStore: ScrollSpeedStore
    let linkTrustStore: LinkTrustStore
    let notificationLifetimeStore: NotificationLifetimeStore
    let oneTitleStore: OneTitleStore
    let agentCloseWarningStore: AgentCloseWarningStore
    let startingFolderStore: StartingFolderStore
    let rearrangeAfterMoveStore: RearrangeAfterMoveStore
    let missionBottomLineStore: MissionBottomLineStore
    let overviewReturnStore: OverviewReturnStore
    let overviewInclusionStore: OverviewInclusionStore
    let allWorkspacesModeStore: AllWorkspacesModeStore
    let railWidthStore: RailWidthStore
    let sectionCollapseStore: SectionCollapseStore
    let paletteRecents: PaletteRecentsStore

    let workspaceIdentityStore: WorkspaceIdentityStore
    let topBarOverlaySizeStore: TopBarOverlaySizeStore
    let workspaceSwitcher: WorkspaceSwitcher
    let tabSwitcher: TabSwitcher

    let toastCenter: ToastCenter
    let chatStore: ChatStore
    let herdrStore: HerdrStore
    let undoJournal: UndoJournal
    let ghosttyFactory: GhosttyControlSurfaceFactory?
    let paneScrollSubscriber: HerdrPaneScrollSubscriber
    let paneAgentStatusSubscriber: HerdrPaneAgentStatusSubscriber
    let viewModel: SessionViewModel
    /// Holds the view model strongly, so it must go with the session.
    let herdrHoldCoordinator: HerdrHoldCoordinator
    let rearrangeMode: RearrangeMode
    let dragCoordinator: DragCoordinator
    let dividerDragCoordinator: DividerDragCoordinator
    let commandPalette: CommandPaletteState

    init(
        context: ProfileSessionContext,
        ghosttyHost: GhosttyHost?,
        board: BoardStore,
        herdProgress: HerdProgressStore,
        resnapshotInterval: Duration?,
        home: String = NSHomeDirectory()
    ) {
        let preferences = context.preferences
        let idState = context.idState
        let socketPath = context.socketPath
        profile = context.profile
        self.socketPath = socketPath
        address = HerdrServerAddress(socketPath: socketPath, home: home)

        let themeStore = ThemeStore(userDefaults: preferences)
        self.themeStore = themeStore
        let terminalTextSizeStore = TerminalTextSizeStore(userDefaults: preferences)
        self.terminalTextSizeStore = terminalTextSizeStore
        rtModalSizeStore = RtModalSizeStore(userDefaults: preferences)
        rtModalTextSizeStore = RtModalTextSizeStore(userDefaults: preferences)
        topBarLabelStore = TopBarLabelStore(userDefaults: preferences)
        let optionAsAltStore = OptionAsAltStore(userDefaults: preferences)
        self.optionAsAltStore = optionAsAltStore
        let scrollSpeedStore = ScrollSpeedStore(userDefaults: preferences)
        self.scrollSpeedStore = scrollSpeedStore
        let linkTrustStore = LinkTrustStore(userDefaults: preferences)
        self.linkTrustStore = linkTrustStore
        let notificationLifetimeStore = NotificationLifetimeStore(userDefaults: preferences)
        self.notificationLifetimeStore = notificationLifetimeStore
        let oneTitleStore = OneTitleStore(userDefaults: preferences)
        self.oneTitleStore = oneTitleStore
        let agentCloseWarningStore = AgentCloseWarningStore(userDefaults: preferences)
        self.agentCloseWarningStore = agentCloseWarningStore
        let startingFolderStore = StartingFolderStore(userDefaults: preferences)
        self.startingFolderStore = startingFolderStore
        let rearrangeAfterMoveStore = RearrangeAfterMoveStore(userDefaults: preferences)
        self.rearrangeAfterMoveStore = rearrangeAfterMoveStore
        missionBottomLineStore = MissionBottomLineStore(userDefaults: preferences)
        let overviewReturnStore = OverviewReturnStore(userDefaults: preferences)
        self.overviewReturnStore = overviewReturnStore
        overviewInclusionStore = OverviewInclusionStore(userDefaults: preferences)
        allWorkspacesModeStore = AllWorkspacesModeStore(userDefaults: preferences)
        railWidthStore = RailWidthStore(userDefaults: preferences)
        sectionCollapseStore = SectionCollapseStore(userDefaults: preferences)
        paletteRecents = PaletteRecentsStore(userDefaults: preferences)

        let workspaceIdentityStore = WorkspaceIdentityStore(userDefaults: idState)
        self.workspaceIdentityStore = workspaceIdentityStore
        topBarOverlaySizeStore = TopBarOverlaySizeStore(userDefaults: idState)
        workspaceSwitcher = WorkspaceSwitcher(userDefaults: idState)
        tabSwitcher = TabSwitcher(userDefaults: idState)

        let toastCenter = ToastCenter()
        self.toastCenter = toastCenter
        // `ChatStore`'s own init resolves `ChatToolLocator.binaryPath` off the
        // main actor via its `probeTask`; nothing here reads it synchronously.
        chatStore = ChatStore(toasts: toastCenter)
        let herdrStore = resnapshotInterval.map { HerdrStore(socketPath: socketPath, resnapshotInterval: $0) }
            ?? HerdrStore(socketPath: socketPath)
        self.herdrStore = herdrStore
        let undoJournal = UndoJournal(
            executor: herdrStore,
            model: { herdrStore.model },
            notify: { message in toastCenter.show(message) }
        )
        self.undoJournal = undoJournal
        // Absent only when libghostty itself failed to initialize (see
        // `GhosttyHost.Failure`): every pane then stays in status-card mode
        // with no live attach at all, rather than the app failing to launch.
        let ghosttyFactory = ghosttyHost.map { host in
            GhosttyControlSurfaceFactory(
                host: host, socketPath: socketPath,
                themeColors: { themeStore.active.ghosttyThemeColors() },
                fontSizePoints: { terminalTextSizeStore.points },
                optionAsAlt: { optionAsAltStore.active },
                scrollSpeed: { scrollSpeedStore.active },
                linkTrust: linkTrustStore
            )
        }
        self.ghosttyFactory = ghosttyFactory
        // Pane-scoped scroll state rides one subscription connection per
        // visible pane, never the store's blanket subscription; it lands in
        // the same model the blanket feed reduces into.
        let paneScrollSubscriber = HerdrPaneScrollSubscriber(socketPath: socketPath) { pane, scroll in
            herdrStore.applyScrollChanged(pane: pane, scroll: scroll)
        }
        self.paneScrollSubscriber = paneScrollSubscriber
        // Agent status rides its own per-pane connection for the same reason,
        // but armed for EVERY pane herdr reports rather than the visible ones:
        // the rail dot and the attention toasts report the pane nobody is
        // looking at.
        let paneAgentStatusSubscriber = HerdrPaneAgentStatusSubscriber(socketPath: socketPath) { pane, status in
            herdrStore.applyAgentStatusChanged(pane: pane, status: status)
        }
        self.paneAgentStatusSubscriber = paneAgentStatusSubscriber
        // One client, two roles: `HerdrClient` conforms to both
        // `HerdrCommandClient` and `LayoutExportClient`, so the view-model's
        // command verbs and the layout-export coordinator share the same
        // actor rather than opening a second one.
        let herdrClient = HerdrClient(socketPath: socketPath)
        let viewModel = SessionViewModel(
            client: herdrClient,
            ghosttyFactory: ghosttyFactory,
            layoutExportClient: herdrClient,
            planExecutor: herdrStore,
            undoJournal: undoJournal,
            paneScrollSubscriber: paneScrollSubscriber,
            paneAgentStatusSubscriber: paneAgentStatusSubscriber,
            // Not an undo/redo notice -- an invalid move or a plan/herdr
            // failure from `perform`/`closePane` -- so this gets the
            // neutral info glyph, never the undo journal's arrow.
            noticeSink: { message in toastCenter.show(message, kind: .info) },
            notificationLifetime: { notificationLifetimeStore.active },
            attentionToastArchive: AttentionToastArchive(userDefaults: idState),
            paneLastChangeArchive: PaneLastChangeArchive(userDefaults: idState),
            oneTitle: { oneTitleStore.active },
            agentCloseWarning: agentCloseWarningStore,
            startingFolder: { startingFolderStore.choice(for: $0) },
            rtLinkedPaneDefaults: idState,
            rightClickDefaults: idState,
            completedTabDefaults: idState,
            paneTitleDefaults: idState,
            pinnedWorkspaceDefaults: idState,
            identity: workspaceIdentityStore,
            cswapAccounts: CswapList.read
        )
        self.viewModel = viewModel
        herdrHoldCoordinator = HerdrHoldCoordinator(viewModel: viewModel)
        let rearrangeMode = RearrangeMode(afterMove: { rearrangeAfterMoveStore.active })
        self.rearrangeMode = rearrangeMode
        let dragCoordinator = DragCoordinator(
            toasts: toastCenter,
            rearrangeMode: rearrangeMode,
            commit: { subject, target in await viewModel.perform(subject: subject, target: target, board: board.names) },
            // Reveals the dwelled-on tab or workspace in place, which is a
            // local selection only: a `*.focus` RPC mid-drag would move
            // herdr's own focus for what is still just a hover.
            reveal: { target in
                switch target {
                case .tabThumbnail(let id): viewModel.select(tab: id)
                case .workspaceThumbnail(let id): viewModel.select(workspace: id)
                case .paneEdge, .paneInterior, .tabStrip, .newTab, .newWorkspace, .emptyPin, .workspaceRail, .pinnedRail, .topBar: break
                }
            },
            // Repo and branch are read again each time the view opens.
            gridOpened: {
                viewModel.repoBranches.invalidate()
                viewModel.isMainCanvasCovered = true
            },
            gridClosed: { viewModel.isMainCanvasCovered = false },
            gridHoldsEscape: { viewModel.renameTarget != nil || viewModel.paneShownInOverview != nil }
        )
        dragCoordinator.keepsOverviewPane = { overviewReturnStore.active == .openPane }
        self.dragCoordinator = dragCoordinator
        let dividerDragSession = DividerDragSession(
            commit: { tab, path, ratio in await viewModel.setSplitRatio(tab: tab, path: path, ratio: ratio) }
        )
        dividerDragCoordinator = DividerDragCoordinator(session: dividerDragSession)
        commandPalette = CommandPaletteState()
    }

    func start() async {
        await herdrStore.start()
    }

    func shutdown() async {
        herdrHoldCoordinator.invalidate()
        dragCoordinator.invalidate()
        rearrangeMode.invalidate()
        herdrStore.stop()
        await viewModel.shutdown()
        chatStore.stop()
        toastCenter.clear()
    }
}
