import AppKit
import Foundation
import PaddockCore
import SwiftUI

/// Declares (dynamically; `Info.plist`'s `NSApplicationSupportsSecureRestorableState`
/// declares the same thing statically, for the earliest part of launch this
/// delegate is not yet installed for) that this app does not participate in
/// AppKit's secure-restorable-state scheme.
///
/// Also owns window-frame persistence under a fixed literal key, independent
/// of the SwiftUI environment-modifier chain that made state restoration
/// itself unreliable (see `PaddockApp.init`'s own trade-off comment) --
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
final class PaddockAppDelegate: NSObject, NSApplicationDelegate {
    private static let frameDefaultsKey = "paddock.mainWindowFrame"

    private var frameObservers: [NSObjectProtocol] = []

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                kind: .move, accessibilityIdentifier: "paddock.view.movePane.\(name.lowercased())"
            )
        }
        let swaps = directions.map { name, key, direction in
            PaneDirectionCommand(
                title: "Swap Pane \(name)", key: key, modifiers: [.command, .option, .shift], direction: direction,
                kind: .swap, accessibilityIdentifier: "paddock.view.swapPane.\(name.lowercased())"
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

struct PaddockApp: App {
    @NSApplicationDelegateAdaptor(PaddockAppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var terminalTextSizeStore = TerminalTextSizeStore()
    @State private var toastCenter: ToastCenter
    @State private var herdrStore: HerdrStore
    @State private var viewModel: SessionViewModel
    @State private var undoJournal: UndoJournal
    @State private var rearrangeMode: RearrangeMode
    @State private var dragCoordinator: DragCoordinator
    @State private var dividerDragCoordinator: DividerDragCoordinator
    /// Held for the app's life so its notification observers outlive `init`.
    @State private var herdrHoldCoordinator: HerdrHoldCoordinator

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
        // on the `WindowGroup` scene below and `PaddockAppDelegate`'s
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
        // window to a default frame on every launch. `PaddockAppDelegate`
        // restores that half itself, under a fixed literal `UserDefaults`
        // key independent of the modifier-chain identity that made
        // restoration itself unreliable -- see that type's own doc comment
        // for why plain `UserDefaults` is what does this rather than
        // `NSWindow`'s own `setFrameAutosaveName`/`saveFrame(usingName:)`.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        ChromeType.install()
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
        let herdrStore = HerdrStore(socketPath: socketPath)
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
        sessionLabel = Self.sessionLabel(fromSocketPath: socketPath)
    }

    var body: some Scene {
        WindowGroup("Paddock") {
            MainWindow(viewModel: viewModel, sessionLabel: sessionLabel)
                .environment(themeStore)
                .environment(terminalTextSizeStore)
                .environment(toastCenter)
                .environment(undoJournal)
                .environment(rearrangeMode)
                .environment(dragCoordinator)
                .environment(dividerDragCoordinator)
                .background(RearrangeOptionMonitorHost(rearrangeMode: rearrangeMode))
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
                .accessibilityIdentifier("paddock.file.newTab")
                Button("New Workspace") {
                    Task { await viewModel.createWorkspace() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("paddock.file.newWorkspace")
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
                // No key equivalent: the momentary route into rearrange mode
                // is a held Option, not a shortcut on this item.
                Button {
                    rearrangeMode.toggle()
                } label: {
                    if rearrangeMode.isToggled {
                        Label("Rearrange Mode", systemImage: "checkmark")
                    } else {
                        Text("Rearrange Mode")
                    }
                }
                .accessibilityIdentifier("paddock.view.rearrangeMode")
                Button {
                    dragCoordinator.toggleGrid()
                } label: {
                    if dragCoordinator.isGridShown {
                        Label("All Workspaces", systemImage: "checkmark")
                    } else {
                        Text("All Workspaces")
                    }
                }
                // A letter key: SwiftUI does not reliably match a shifted
                // punctuation key equivalent.
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .accessibilityIdentifier("paddock.view.allWorkspaces")
                // The attention stack's only keyboard route, and the only way
                // to clear a "needs input" toast without answering the pane or
                // dismissing each one by hand.
                Button("Clear Notifications") { viewModel.clearAttentionToasts() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(viewModel.attentionToasts.isEmpty)
                    .accessibilityIdentifier("paddock.view.clearNotifications")
            }
            // Rename's macOS home, and the only route to the editor that is
            // not a double-click on the thing itself. It renames the
            // innermost selection, which is the same thing a double-click on
            // that surface would have renamed.
            CommandGroup(after: .pasteboard) {
                Button("Rename") { viewModel.beginRenameFromShortcut() }
                    .keyboardShortcut(.f2, modifiers: [])
                    .disabled(viewModel.renameShortcutTarget == nil)
                    .accessibilityIdentifier("paddock.edit.rename")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(undoJournal.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    Task { await undoJournal.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!undoJournal.canUndo || undoJournal.isBusy)
                .accessibilityIdentifier("paddock.edit.undo")
                Button(undoJournal.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    Task { await undoJournal.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!undoJournal.canRedo || undoJournal.isBusy)
                .accessibilityIdentifier("paddock.edit.redo")
            }
        }
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
