import AppKit
import Foundation
import FlockCore
import SwiftUI

/// Declares (dynamically; `Info.plist`'s `NSApplicationSupportsSecureRestorableState`
/// declares the same thing statically, for the earliest part of launch this
/// delegate is not yet installed for) that this app does not participate in
/// AppKit's secure-restorable-state scheme.
///
/// Also owns window-frame persistence under a fixed literal key, independent
/// of the SwiftUI environment-modifier chain that made state restoration
/// itself unreliable (see `FlockApp.init`'s own trade-off comment) --
/// `NSWindow`'s own `setFrameAutosaveName`/`saveFrame(usingName:)` were tried
/// first and empirically do NOT write anything under a custom name for this
/// window (confirmed: the call sites ran, with a valid window/frame/name
/// each time, and `defaults read` never showed the key; `isRestorable =
/// false` first did not unblock it either) -- this window's frame keeps
/// getting captured under SwiftUI's OWN type-encoded identifier
/// (`NSPersistentUIManager`-driven) instead, no matter what name this code
/// asks for. Plain `UserDefaults` read/write under an ordinary app-owned key
/// sidesteps whatever internal AppKit/SwiftUI interaction is intercepting
/// the classic autosave APIs, and is what `ApplePersistenceIgnoreState`
/// itself already round-trips through in this exact process.
final class FlockAppDelegate: NSObject, NSApplicationDelegate {
    private static let frameDefaultsKey = "flock.mainWindowFrame"

    private var frameObservers: [NSObjectProtocol] = []

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ahead of the window guard below, which returns and would take the
        // sweep with it.
        DispatchQueue.global(qos: .utility).async { ClipboardImageStaging.sweep() }

        guard let window = NSApp.windows.first else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let frame = NSRectFromString(saved)
            // A frame saved on a display that is no longer attached would
            // restore the window somewhere unreachable; only a frame that
            // still overlaps a current screen is honored, and the screen
            // constrains it so the title bar stays grabbable.
            if frame.width > 0, frame.height > 0,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(window.constrainFrameRect(frame, to: screen), display: true)
            }
        }
        // Saved continuously (not only at quit), so a force-quit or crash
        // still keeps the LAST live position/size rather than only
        // whatever `applicationWillTerminate` last saw.
        let center = NotificationCenter.default
        frameObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                Self.saveFrame(of: window)
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak window] _ in
                Self.saveFrame(of: window)
            },
        ]
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.saveFrame(of: NSApp.windows.first)
    }

    private static func saveFrame(of window: NSWindow?) {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey)
    }
}

/// One directional pane command: its title, the arrow that runs it, the
/// modifiers it runs under, and whether it moves the pane past its neighbor
/// or trades places with it. Both families aim at the same neighbor, so both
/// are enabled by the same predicate.
struct PaneDirectionCommand {
    enum Kind { case move, swap }

    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let direction: PaneDirection
    let kind: Kind
    let accessibilityIdentifier: String

    /// Command+Option+arrow moves, Command+Option+Shift+arrow swaps. Neither
    /// combination is claimed by the system, and Shift reading as "and take
    /// the other pane with you" is the same relationship the two gestures
    /// have on the canvas.
    static let all: [PaneDirectionCommand] = {
        let directions: [(String, KeyEquivalent, PaneDirection)] = [
            ("Left", .leftArrow, .left), ("Right", .rightArrow, .right),
            ("Up", .upArrow, .up), ("Down", .downArrow, .down),
        ]
        let moves = directions.map { name, key, direction in
            PaneDirectionCommand(
                title: "Move Pane \(name)", key: key, modifiers: [.command, .option], direction: direction,
                kind: .move, accessibilityIdentifier: "flock.view.movePane.\(name.lowercased())"
            )
        }
        let swaps = directions.map { name, key, direction in
            PaneDirectionCommand(
                title: "Swap Pane \(name)", key: key, modifiers: [.command, .option, .shift], direction: direction,
                kind: .swap, accessibilityIdentifier: "flock.view.swapPane.\(name.lowercased())"
            )
        }
        return moves + swaps
    }()
}

/// F2. There is no `KeyEquivalent` case for a function key, so it is the
/// scalar AppKit itself uses (`NSF2FunctionKey`); the menu equivalent takes
/// no modifier.
extension KeyEquivalent {
    static let f2 = KeyEquivalent("\u{F705}")
}

struct FlockApp: App {
    @NSApplicationDelegateAdaptor(FlockAppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var terminalTextSizeStore = TerminalTextSizeStore()
    @State private var railWidthStore = RailWidthStore()
    @State private var toastCenter: ToastCenter
    @State private var herdrStore: HerdrStore
    @State private var viewModel: SessionViewModel
    @State private var undoJournal: UndoJournal
    @State private var rearrangeMode: RearrangeMode
    @State private var dragCoordinator: DragCoordinator
    @State private var dividerDragCoordinator: DividerDragCoordinator
    /// Held for the app's life so its notification observers outlive `init`.
    @State private var herdrHoldCoordinator: HerdrHoldCoordinator
    @State private var prefixKeys: PrefixKeyController

    private let sessionLabel: String

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
        ToolPath.warm(reporting: ["herdr"] + HarnessRoster.known.map(\.binary))
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
        let toastCenter = ToastCenter()
        _toastCenter = State(initialValue: toastCenter)
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
                fontSizePoints: { terminalTextSizeStore.points }
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
            noticeSink: { message in toastCenter.show(message, kind: .info) }
        )
        _viewModel = State(initialValue: viewModel)
        _herdrHoldCoordinator = State(initialValue: HerdrHoldCoordinator(viewModel: viewModel))
        let rearrangeMode = RearrangeMode()
        _rearrangeMode = State(initialValue: rearrangeMode)
        _dragCoordinator = State(initialValue: DragCoordinator(
            toasts: toastCenter,
            rearrangeMode: rearrangeMode,
            commit: { subject, target in await viewModel.perform(subject: subject, target: target) },
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
        // The user's own herdr keymap, resolved the way herdr resolves it, so
        // the prefix key does in flock what it does in a herdr terminal.
        let configPath = HerdrConfigLocation.path(
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory()
        )
        _prefixKeys = State(initialValue: PrefixKeyController(
            source: HerdrKeybindingsSource(
                stamp: { Self.stamp(ofFileAt: configPath) },
                contents: { try? String(contentsOfFile: configPath, encoding: .utf8) }
            ),
            isTyping: { viewModel.renameEditorIsOnScreen },
            context: { Self.prefixContext(viewModel) },
            run: { intent in Self.run(intent, viewModel: viewModel, toasts: toastCenter) }
        ))
        sessionLabel = Self.sessionLabel(fromSocketPath: socketPath)
    }

    private static func stamp(ofFileAt path: String) -> HerdrConfigStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return HerdrConfigStamp(modified: modified, size: size)
    }

    private static func prefixContext(_ viewModel: SessionViewModel) -> PrefixActionContext {
        PrefixActionContext(
            focusedPane: viewModel.resolvedFocusedPaneID,
            selectedWorkspace: viewModel.selectedWorkspaceID,
            selectedTab: viewModel.selectedTabID,
            workspaces: viewModel.model?.workspaces.map(\.workspaceID) ?? [],
            tabs: viewModel.tabsForSelectedWorkspace.map(\.tabID),
            layout: viewModel.selectedLayout
        )
    }

    /// The one place a herdr binding becomes a flock call. Every verb here is
    /// the same one the equivalent menu item or click runs, `jumpToHerdr`
    /// included: a key that moves flock's selection moves herdr's focus with
    /// it, exactly as clicking that tab would.
    @MainActor
    private static func run(_ intent: PrefixIntent, viewModel: SessionViewModel, toasts: ToastCenter) {
        switch intent {
        case .focusPane(let pane): Task { await viewModel.jumpToHerdr(pane: pane) }
        case .selectTab(let tab): Task { await viewModel.jumpToHerdr(tab: tab) }
        case .selectWorkspace(let workspace): Task { await viewModel.jumpToHerdr(workspace: workspace) }
        case .splitRight(let pane): Task { await viewModel.splitRight(from: pane) }
        case .splitDown(let pane): Task { await viewModel.splitDown(from: pane) }
        case .closePane(let pane): Task { await viewModel.closePane(pane) }
        case .closeTab(let tab): Task { await viewModel.closeTab(tab) }
        case .closeWorkspace(let workspace): Task { await viewModel.closeWorkspace(workspace) }
        case .newTab(let workspace): Task { await viewModel.createTab(in: workspace) }
        case .newWorkspace: Task { await viewModel.createWorkspace() }
        case .toggleZoom(let pane): Task { await viewModel.toggleZoom(pane) }
        case .swapPane(let pane, let direction): Task { await viewModel.swapPane(pane, toward: direction) }
        case .beginRename(let target): viewModel.beginRename(target)
        case .notice(let message): toasts.show(message, kind: .info)
        case .nothing: break
        }
    }

    var body: some Scene {
        WindowGroup("Flock") {
            MainWindow(viewModel: viewModel, sessionLabel: sessionLabel)
                .environment(themeStore)
                .environment(terminalTextSizeStore)
                .environment(railWidthStore)
                .environment(toastCenter)
                .environment(undoJournal)
                .environment(rearrangeMode)
                .environment(dragCoordinator)
                .environment(dividerDragCoordinator)
                .background(RearrangeKeyMonitorHost(rearrangeMode: rearrangeMode))
                .background(PrefixKeyMonitorHost(controller: prefixKeys))
                .task { await herdrStore.start() }
                .onChange(of: herdrStore.model) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                }
                .onChange(of: herdrStore.connection) {
                    viewModel.update(model: herdrStore.model, connection: herdrStore.connection)
                }
        }
        .windowStyle(.hiddenTitleBar)
        // Declarative opt-out of SwiftUI's own scene-restoration bookkeeping
        // for this scene, alongside the two lower-level opt-outs above.
        .restorationBehavior(.disabled)
        .commands {
            PasteboardCommands()
            // Creation's macOS home. It is also the only always-visible route
            // to it: the strip and rail take a plain click on their own empty
            // space, and the tab menu carries New Tab, but neither the strip
            // nor the rail draws a control the chrome design never had.
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    guard let workspace = viewModel.selectedWorkspaceID else { return }
                    Task { await viewModel.createTab(in: workspace) }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(viewModel.selectedWorkspaceID == nil)
                .accessibilityIdentifier("flock.file.newTab")
                Button("New Workspace") {
                    Task { await viewModel.createWorkspace() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("flock.file.newWorkspace")
            }
            CommandGroup(after: .sidebar) {
                Divider()
                // The spec's keyboard-parity half of the drag inventory: each
                // one compiles the same plan the equivalent drag would,
                // through the same planner.
                ForEach(PaneDirectionCommand.all, id: \.title) { command in
                    Button(command.title) {
                        Task {
                            switch command.kind {
                            case .move: await viewModel.moveFocusedPane(toward: command.direction)
                            case .swap: await viewModel.swapFocusedPane(toward: command.direction)
                            }
                        }
                    }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(!viewModel.focusedPaneHasNeighbor(toward: command.direction))
                    .accessibilityIdentifier(command.accessibilityIdentifier)
                }
                Divider()
            }
            CommandGroup(after: .sidebar) {
                ThemeMenu(themeStore: themeStore)
                TerminalTextSizeMenu(store: terminalTextSizeStore)
                // The only key into rearrange mode, and the same switch this
                // item's checkmark reflects.
                Button {
                    rearrangeMode.toggle()
                } label: {
                    if rearrangeMode.isToggled {
                        Label("Rearrange Mode", systemImage: "checkmark")
                    } else {
                        Text("Rearrange Mode")
                    }
                }
                .keyboardShortcut(ArrangeShortcut.rearrangeMode.shortcut)
                .accessibilityIdentifier("flock.view.rearrangeMode")
                Button {
                    dragCoordinator.toggleGrid()
                } label: {
                    if dragCoordinator.isGridShown {
                        Label("All Workspaces", systemImage: "checkmark")
                    } else {
                        Text("All Workspaces")
                    }
                }
                .keyboardShortcut(ArrangeShortcut.allWorkspaces.shortcut)
                .accessibilityIdentifier("flock.view.allWorkspaces")
                // The attention stack's only keyboard route, and the only way
                // to clear a "needs input" toast without answering the pane or
                // dismissing each one by hand.
                Button("Clear Notifications") { viewModel.clearAttentionToasts() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(viewModel.attentionToasts.isEmpty)
                    .accessibilityIdentifier("flock.view.clearNotifications")
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

    private static func resolveSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["HERDR_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    /// `.../sessions/<name>/herdr.sock` -> `<name>`; the default socket's
    /// parent directory is `herdr` itself, shown as "default".
    private static func sessionLabel(fromSocketPath socketPath: String) -> String {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().lastPathComponent
        guard parent != "herdr" else { return "default" }
        return parent
    }
}
