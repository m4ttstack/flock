import AppKit
import Foundation
import FlockCore
import SwiftUI

/// Declares (dynamically; `Info.plist`'s `NSApplicationSupportsSecureRestorableState`
/// declares the same thing statically, for the earliest part of launch this
/// delegate is not yet installed for) that this app does not participate in
/// AppKit's secure-restorable-state scheme.
///
/// Also starts window-frame persistence, which `MainWindowFrameKeeper` then
/// owns. The frame is kept under a fixed literal `UserDefaults` key,
/// independent of the SwiftUI environment-modifier chain that made state
/// restoration itself unreliable (see `FlockApp.init`'s own trade-off
/// comment) -- `NSWindow`'s own `setFrameAutosaveName`/`saveFrame(usingName:)`
/// were tried first and empirically do NOT write anything under a custom name
/// for this window (confirmed: the call sites ran, with a valid
/// window/frame/name each time, and `defaults read` never showed the key;
/// `isRestorable = false` first did not unblock it either) -- this window's
/// frame keeps getting captured under SwiftUI's OWN type-encoded identifier
/// (`NSPersistentUIManager`-driven) instead, no matter what name this code
/// asks for. Plain `UserDefaults` read/write under an ordinary app-owned key
/// sidesteps whatever internal AppKit/SwiftUI interaction is intercepting
/// the classic autosave APIs, and is what `ApplePersistenceIgnoreState`
/// itself already round-trips through in this exact process.
@MainActor
final class FlockAppDelegate: NSObject, NSApplicationDelegate {
    private let windowFrame = MainWindowFrameKeeper()

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    /// Whether the SwiftUI window exists by the time either launch callback
    /// runs is not something the app gets to know, so the keeper is started
    /// from both and is built to be started twice.
    func applicationWillFinishLaunching(_ notification: Notification) {
        windowFrame.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { ClipboardImageStaging.sweep() }
        windowFrame.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowFrame.save()
    }
}

struct FlockApp: App {
    @NSApplicationDelegateAdaptor(FlockAppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var terminalTextSizeStore = TerminalTextSizeStore()
    @State private var rtModalSizeStore = RtModalSizeStore()
    @State private var rtModalTextSizeStore = RtModalTextSizeStore()
    @State private var optionAsAltStore = OptionAsAltStore()
    @State private var notificationLifetimeStore: NotificationLifetimeStore
    @State private var rearrangeAfterMoveStore: RearrangeAfterMoveStore
    @State private var scrollSpeedStore = ScrollSpeedStore()
    @State private var railWidthStore = RailWidthStore()
    @State private var sectionCollapseStore = SectionCollapseStore()
    @State private var boardStore: BoardStore
    @State private var devBuildWatcher: DevBuildWatcher? = BuildFlavor.isDev ? DevBuildWatcher() : nil
    @State private var herdProgressStore = HerdProgressStore()
    @State private var toastCenter: ToastCenter
    @State private var chatStore: ChatStore
    @State private var herdrStore: HerdrStore
    @State private var herdrToolStore = HerdrToolStore()
    @State private var isStartingHerdr = false
    @State private var herdrStartFailure: String?
    @State private var herdrMousePatchStore = HerdrMousePatchStore()
    @State private var viewModel: SessionViewModel
    @State private var undoJournal: UndoJournal
    @State private var rearrangeMode: RearrangeMode
    @State private var dragCoordinator: DragCoordinator
    @State private var dividerDragCoordinator: DividerDragCoordinator
    @State private var commandPalette = CommandPaletteState()
    @State private var paletteRecents = PaletteRecentsStore()
    @State private var workspaceSwitcher = WorkspaceSwitcher()
    /// Held for the app's life so its notification observers outlive `init`.
    @State private var herdrHoldCoordinator: HerdrHoldCoordinator
    #if FLOCK_SPARKLE
    @State private var updater = Updater()
    #endif

    private let sessionLabel: String
    private let socketPath: String

    init() {
        // The one setting that actually stops AppKit's legacy
        // `NSPersistentUIRestorationSupport` path (`_reopenWindowsAsNecessaryIncludingRestorableState`)
        // from running before this app's own window is ever created: a
        // window-restore attempt against ANY identifier this scene's own
        // modifier chain does not currently produce byte-for-byte resolves
        // to a null window with no error, and nothing then falls back to
        // creating a fresh default window -- a zero-window launch with no
        // crash and no visible error anywhere. `.restorationBehavior(.disabled)`
        // on the `WindowGroup` scene below and `FlockAppDelegate`'s
        // `applicationSupportsSecureRestorableState` are the documented,
        // forward-looking way to say the same thing, but both install too
        // late to preempt THIS specific legacy path (confirmed empirically:
        // neither stopped it). This is the equivalent of always launching
        // with `-ApplePersistenceIgnoreState YES`.
        //
        // The trade-off, stated plainly: full scene-CONTENT state
        // restoration is off for good, traded for a launch that never opens
        // zero windows. It also takes window FRAME persistence down with it
        // -- SwiftUI saves "NSWindow Frame <the same type-encoded
        // identifier>" as a side effect of the very restoration machinery
        // this disables, so this line alone would silently reset the
        // window to a default frame on every launch. `FlockAppDelegate`
        // restores that half itself, under a fixed literal `UserDefaults`
        // key independent of the modifier-chain identity that made
        // restoration itself unreliable -- see that type's own doc comment
        // for why plain `UserDefaults` is what does this rather than
        // `NSWindow`'s own `setFrameAutosaveName`/`saveFrame(usingName:)`.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        ChromeType.install()
        // Ahead of everything that resolves a tool, because the first pane's
        // bridge is handed the herdr binary it resolves and a reader that gets
        // there first has to wait for it.
        ToolPath.warm(reporting: ["herdr", "rt", "deck"] + HarnessRoster.known.map(\.binary))
        let socketPath = Self.resolveSocketPath()
        // A plain local, not `self.themeStore`: an escaping closure built
        // here (below) cannot capture any part of `self` before every stored
        // property is assigned, so this is constructed once, up front, and
        // both `_themeStore` and the closure below capture THIS reference
        // rather than reading it back off `self`.
        let themeStore = ThemeStore()
        _themeStore = State(initialValue: themeStore)
        let terminalTextSizeStore = TerminalTextSizeStore()
        _terminalTextSizeStore = State(initialValue: terminalTextSizeStore)
        let optionAsAltStore = OptionAsAltStore()
        _optionAsAltStore = State(initialValue: optionAsAltStore)
        let scrollSpeedStore = ScrollSpeedStore()
        _scrollSpeedStore = State(initialValue: scrollSpeedStore)
        let notificationLifetimeStore = NotificationLifetimeStore()
        _notificationLifetimeStore = State(initialValue: notificationLifetimeStore)
        let toastCenter = ToastCenter()
        _toastCenter = State(initialValue: toastCenter)
        // `ChatStore`'s own init resolves `ChatToolLocator.binaryPath` off the
        // main actor via its `probeTask`; nothing here reads it synchronously.
        let chatStore = ChatStore(toasts: toastCenter)
        _chatStore = State(initialValue: chatStore)
        let herdrStore = Self.makeHerdrStore(socketPath: socketPath)
        _herdrStore = State(initialValue: herdrStore)
        let undoJournal = UndoJournal(
            executor: herdrStore,
            model: { herdrStore.model },
            notify: { message in toastCenter.show(message) }
        )
        _undoJournal = State(initialValue: undoJournal)
        // Absent only when libghostty itself failed to initialize (see
        // `GhosttyHost.Failure`): every pane then stays in status-card mode
        // with no live attach at all, rather than the app failing to launch.
        let ghosttyHost = try? GhosttyHost()
        ghosttyHost?.onClipboardWrite = { text, paneID in
            toastCenter.show(CopiedToastMessage.make(for: text), kind: .copied, in: paneID)
        }
        let ghosttyFactory = ghosttyHost.map { host in
            GhosttyControlSurfaceFactory(
                host: host, socketPath: socketPath,
                themeColors: { themeStore.active.ghosttyThemeColors() },
                fontSizePoints: { terminalTextSizeStore.points },
                optionAsAlt: { optionAsAltStore.active },
                scrollSpeed: { scrollSpeedStore.active }
            )
        }
        // Pane-scoped scroll state rides one subscription connection per
        // visible pane, never the store's blanket subscription; it lands in
        // the same model the blanket feed reduces into.
        let paneScrollSubscriber = HerdrPaneScrollSubscriber(socketPath: socketPath) { pane, scroll in
            herdrStore.applyScrollChanged(pane: pane, scroll: scroll)
        }
        // Agent status rides its own per-pane connection for the same reason,
        // but armed for EVERY pane herdr reports rather than the visible ones:
        // the rail dot and the attention toasts report the pane nobody is
        // looking at.
        let paneAgentStatusSubscriber = HerdrPaneAgentStatusSubscriber(socketPath: socketPath) { pane, status in
            herdrStore.applyAgentStatusChanged(pane: pane, status: status)
        }
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
            attentionToastArchive: AttentionToastArchive(),
            rightClickDefaults: .standard
        )
        _viewModel = State(initialValue: viewModel)
        _herdrHoldCoordinator = State(initialValue: HerdrHoldCoordinator(viewModel: viewModel))
        let rearrangeAfterMoveStore = RearrangeAfterMoveStore()
        _rearrangeAfterMoveStore = State(initialValue: rearrangeAfterMoveStore)
        let rearrangeMode = RearrangeMode(afterMove: { rearrangeAfterMoveStore.active })
        _rearrangeMode = State(initialValue: rearrangeMode)
        let boardStore = BoardStore()
        _boardStore = State(initialValue: boardStore)
        _dragCoordinator = State(initialValue: DragCoordinator(
            toasts: toastCenter,
            rearrangeMode: rearrangeMode,
            commit: { subject, target in await viewModel.perform(subject: subject, target: target, board: boardStore.names) },
            // Reveals the dwelled-on tab or workspace in place, which is a
            // local selection only: a `*.focus` RPC mid-drag would move
            // herdr's own focus for what is still just a hover.
            reveal: { target in
                switch target {
                case .tabThumbnail(let id): viewModel.select(tab: id)
                case .workspaceThumbnail(let id): viewModel.select(workspace: id)
                case .paneEdge, .paneInterior, .tabStrip, .newTab, .newWorkspace, .workspaceRail, .moreTabs: break
                }
            }
        ))
        let dividerDragSession = DividerDragSession(
            commit: { tab, path, ratio in await viewModel.setSplitRatio(tab: tab, path: path, ratio: ratio) }
        )
        _dividerDragCoordinator = State(initialValue: DividerDragCoordinator(session: dividerDragSession))
        sessionLabel = Self.sessionLabel(fromSocketPath: socketPath)
        self.socketPath = socketPath
    }

    private var notRunningCopy: NoHerdrScreen.Copy {
        let copy = NoHerdrScreen.notRunning
        guard let herdrStartFailure else { return copy }
        return NoHerdrScreen.Copy(headline: copy.headline, body: copy.body, hint: herdrStartFailure)
    }

    /// The store is already retrying the socket, so a server that comes up is
    /// picked up by it; this only lets the button be pressed again if none did.
    private func startHerdr() {
        herdrStartFailure = nil
        switch HerdrServerLauncher.start() {
        case .success:
            isStartingHerdr = true
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard isStartingHerdr, case .notRunning = viewModel.connectionState else { return }
                isStartingHerdr = false
                herdrStartFailure = "herdr didn't come up. Try running herdr in a terminal to see why."
            }
        case .failure(.notFound):
            herdrStartFailure = "flock couldn't find herdr on its PATH."
        case .failure(.spawn(let code)):
            herdrStartFailure = "herdr wouldn't start (\(String(cString: strerror(code))))."
        }
    }

    var body: some Scene {
        WindowGroup("Flock") {
            Group {
                if HerdrAvailability.shouldShowMissingScreen(herdrBinaryFound: herdrToolStore.isFound) {
                    NoHerdrScreen(theme: themeStore.active)
                } else if case .notRunning = viewModel.connectionState {
                    NoHerdrScreen(
                        theme: themeStore.active, copy: notRunningCopy,
                        primaryAction: .init(
                            title: isStartingHerdr ? "Starting herdr…" : "Start herdr",
                            isDisabled: isStartingHerdr, perform: startHerdr
                        )
                    )
                } else {
                    MainWindow(
                        viewModel: viewModel,
                        sessionLabel: sessionLabel,
                        herdrMousePatchStore: herdrMousePatchStore
                    )
                }
            }
                .environment(themeStore)
                .environment(terminalTextSizeStore)
                .environment(rtModalSizeStore)
                .environment(rtModalTextSizeStore)
                .environment(optionAsAltStore)
                .environment(railWidthStore)
                .environment(sectionCollapseStore)
                .environment(boardStore)
                .environment(devBuildWatcher)
                .environment(herdProgressStore)
                .environment(toastCenter)
                .environment(chatStore)
                .environment(undoJournal)
                .environment(rearrangeMode)
                .environment(dragCoordinator)
                .environment(dividerDragCoordinator)
                .environment(commandPalette)
                .environment(paletteRecents)
                .environment(workspaceSwitcher)
                .background(RearrangeKeyMonitorHost(rearrangeMode: rearrangeMode))
                .task {
                    await FlockClientGuard.settle(socketPath: socketPath, defaultSocketPath: Self.defaultSocketPath)
                    await herdrStore.start()
                }
                .task { await boardStore.refresh() }
                .task { devBuildWatcher?.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await boardStore.refresh() }
                    devBuildWatcher?.check()
                }
                .onChange(of: herdrStore.model) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                }
                .onChange(of: herdrStore.connection) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                    if case .notRunning = herdrStore.connection { return }
                    isStartingHerdr = false
                    herdrStartFailure = nil
                }
        }
        .windowStyle(.hiddenTitleBar)
        // Declarative opt-out of SwiftUI's own scene-restoration bookkeeping
        // for this scene, alongside the two lower-level opt-outs above.
        .restorationBehavior(.disabled)
        .commands {
            #if FLOCK_SPARKLE
            CheckForUpdatesCommands(updater: updater)
            #endif
            PasteboardCommands()
            ChatCommands(
                chatStore: chatStore, viewModel: viewModel,
                rows: ChatMenuModel.rows(
                    isAvailable: chatStore.isAvailable, hasFocusedPane: viewModel.resolvedFocusedPaneID != nil,
                    isSignedIn: viewModel.resolvedFocusedPaneID.flatMap { chatStore.status(for: $0) }?.signedIn ?? false,
                    viewerDisabledReason: chatStore.viewerDisabledReason
                )
            )
            // Creation's macOS home. It is also the only always-visible route
            // to it: the strip and rail take a plain click on their own empty
            // space, and the tab menu carries New Tab, but neither the strip
            // nor the rail draws a control the chrome design never had.
            CommandGroup(replacing: .newItem) {
                Button(ViewCommand.newTab.title) {
                    guard let workspace = viewModel.selectedWorkspaceID else { return }
                    Task { await viewModel.createTab(in: workspace) }
                }
                .keyboardShortcut(ViewCommand.newTab.shortcut)
                .disabled(viewModel.selectedWorkspaceID == nil)
                .accessibilityIdentifier(ViewCommand.newTab.accessibilityIdentifier)
                Button(ViewCommand.newWorkspace.title) {
                    Task { await viewModel.createWorkspace() }
                }
                .keyboardShortcut(ViewCommand.newWorkspace.shortcut)
                .accessibilityIdentifier(ViewCommand.newWorkspace.accessibilityIdentifier)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                // The pane's own right-click rows, reachable from the keyboard
                // and aimed at the canvas's focused pane rather than at the
                // pane under the pointer. None while the rt modal is up: the
                // pane behind it is the one its items are linked to, and
                // closing it would take them all down.
                ForEach(FocusedPaneCommand.all, id: \.title) { command in
                    Button(command.title) {
                        guard let pane = viewModel.canvasFocusedPaneID else { return }
                        Task { await command.action.perform(paneID: pane, on: viewModel) }
                    }
                    .keyboardShortcut(command.shortcut)
                    .disabled(viewModel.canvasFocusedPaneID == nil)
                    .accessibilityIdentifier(command.accessibilityIdentifier)
                }
                // Takes Minimize All's key: this menu comes before Window.
                Button(RightClickToggle.title(for: viewModel.focusedPaneRightClickMode)) {
                    viewModel.toggleFocusedPaneRightClicks()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(viewModel.focusedPaneRightClickMode == nil)
                .accessibilityIdentifier("flock.view.toggleRightClicks")
                Divider()
                // Move and swap compile the plan the equivalent drag would,
                // through the same planner; focus is a click on the neighbor.
                ForEach(PaneDirectionCommand.all, id: \.title) { command in
                    Button(command.title) {
                        Task {
                            switch command.kind {
                            case .focus: await viewModel.focusNeighbor(toward: command.direction)
                            case .move: await viewModel.moveFocusedPane(toward: command.direction)
                            case .swap: await viewModel.swapFocusedPane(toward: command.direction)
                            }
                        }
                    }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    // herdr's focused pane, which the rt modal does not hold.
                    .disabled(!viewModel.focusedPaneHasNeighbor(toward: command.direction) || viewModel.rt.modal != nil)
                    .accessibilityIdentifier(command.accessibilityIdentifier)
                }
                Divider()
                ForEach(TabStepCommand.allCases, id: \.self) { command in
                    Button(command.title) {
                        guard let tab = viewModel.neighborTab(step: command.step) else { return }
                        Task { await viewModel.jumpToHerdr(tab: tab) }
                    }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(viewModel.neighborTab(step: command.step) == nil || viewModel.rt.modal != nil)
                    .accessibilityIdentifier(command.accessibilityIdentifier)
                }
                Divider()
                // Live only while the focused pane shows the launcher, which
                // is only ever over an idle prompt; disabled, ⌘1 and on reach
                // the pane's program as they did before.
                let launcherPane = viewModel.canvasFocusedPaneID.flatMap { viewModel.isPristineLauncherPane($0) ? $0 : nil }
                ForEach(Array(LauncherSlots.current().enumerated()), id: \.element.id) { index, entry in
                    Button(LauncherSlots.title(for: entry)) {
                        guard let launcherPane else { return }
                        Task { await LauncherSlots.launch(entry, in: launcherPane, on: viewModel) }
                    }
                    .keyboardShortcut(LauncherSlots.key(at: index), modifiers: .command)
                    .disabled(launcherPane == nil)
                    .accessibilityIdentifier("flock.view.launch.\(entry.id)")
                }
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(ViewCommand.commandPalette.title) { commandPalette.toggle() }
                    .keyboardShortcut(ViewCommand.commandPalette.shortcut)
                    // The rename field keeps ⌘K while it is open, and the
                    // grid covers the tab area the palette draws over.
                    .disabled(viewModel.renameEditorIsOnScreen || dragCoordinator.isGridShown)
                    .accessibilityIdentifier(ViewCommand.commandPalette.accessibilityIdentifier)
                Divider()
                ThemeMenu(themeStore: themeStore)
                TerminalTextSizeMenu(
                    panes: terminalTextSizeStore, modal: rtModalTextSizeStore, shownModalKind: { viewModel.rt.modalItem?.kind }
                )
                OptionAsAltMenu(store: optionAsAltStore)
                ScrollSpeedMenu(store: scrollSpeedStore)
                // The only key into rearrange mode, and the same switch this
                // item's checkmark reflects.
                Button {
                    rearrangeMode.toggle()
                } label: {
                    if rearrangeMode.isToggled {
                        Label(ViewCommand.rearrangeMode.title, systemImage: "checkmark")
                    } else {
                        Text(ViewCommand.rearrangeMode.title)
                    }
                }
                .keyboardShortcut(ViewCommand.rearrangeMode.shortcut)
                .accessibilityIdentifier(ViewCommand.rearrangeMode.accessibilityIdentifier)
                Button {
                    dragCoordinator.toggleGrid()
                } label: {
                    if dragCoordinator.isGridShown {
                        Label(ViewCommand.allWorkspaces.title, systemImage: "checkmark")
                    } else {
                        Text(ViewCommand.allWorkspaces.title)
                    }
                }
                .keyboardShortcut(ViewCommand.allWorkspaces.shortcut)
                .accessibilityIdentifier(ViewCommand.allWorkspaces.accessibilityIdentifier)
                Button(ViewCommand.openOldestNotification.title) {
                    Task { await viewModel.jumpToOldestDisplayedAttentionToast() }
                }
                .keyboardShortcut(ViewCommand.openOldestNotification.shortcut)
                .disabled(viewModel.attentionToasts.isEmpty)
                .accessibilityIdentifier(ViewCommand.openOldestNotification.accessibilityIdentifier)
                // The only way to clear a "needs input" toast without
                // answering the pane or dismissing each one by hand.
                Button(ViewCommand.clearNotifications.title) { viewModel.clearAttentionToasts() }
                    .keyboardShortcut(ViewCommand.clearNotifications.shortcut)
                    .disabled(viewModel.attentionToasts.isEmpty)
                    .accessibilityIdentifier(ViewCommand.clearNotifications.accessibilityIdentifier)
            }
            // Rename's macOS home, and the only route to the editor that is
            // not a double-click on the thing itself. It renames the
            // innermost selection, which is the same thing a double-click on
            // that surface would have renamed.
            CommandGroup(after: .pasteboard) {
                Button("Rename") { viewModel.beginRenameFromShortcut() }
                    .keyboardShortcut(.f2, modifiers: [])
                    .disabled(viewModel.renameShortcutTarget == nil)
                    .accessibilityIdentifier("flock.edit.rename")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(undoJournal.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    Task { await undoJournal.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!undoJournal.canUndo || undoJournal.isBusy)
                .accessibilityIdentifier("flock.edit.undo")
                Button(undoJournal.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    Task { await undoJournal.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!undoJournal.canRedo || undoJournal.isBusy)
                .accessibilityIdentifier("flock.edit.redo")
            }
        }

        Settings {
            FlockSettingsView(
                herdrMousePatchStore: herdrMousePatchStore,
                notificationLifetimeStore: notificationLifetimeStore,
                rearrangeAfterMoveStore: rearrangeAfterMoveStore
            )
        }
    }

    /// The store's own re-snapshot backstop is minutes wide, which is longer
    /// than any test can wait to watch it fire; `FLOCK_RESNAPSHOT_SECONDS`
    /// narrows it. An absent, unparseable or non-positive value leaves the
    /// store's default in place rather than inventing a substitute.
    private static func makeHerdrStore(socketPath: String) -> HerdrStore {
        guard let raw = ProcessInfo.processInfo.environment["FLOCK_RESNAPSHOT_SECONDS"],
              let seconds = Double(raw), seconds > 0 else {
            return HerdrStore(socketPath: socketPath)
        }
        return HerdrStore(socketPath: socketPath, resnapshotInterval: .seconds(seconds))
    }

    private static let defaultSocketPath = NSHomeDirectory() + "/.config/herdr/herdr.sock"

    private static func resolveSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["HERDR_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return defaultSocketPath
    }

    /// `.../sessions/<name>/herdr.sock` -> `<name>`; the default socket's
    /// parent directory is `herdr` itself, shown as "default".
    private static func sessionLabel(fromSocketPath socketPath: String) -> String {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().lastPathComponent
        guard parent != "herdr" else { return "default" }
        return parent
    }
}
