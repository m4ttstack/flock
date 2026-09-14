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

struct PaddockApp: App {
    @NSApplicationDelegateAdaptor(PaddockAppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var terminalTextSizeStore = TerminalTextSizeStore()
    @State private var toastCenter: ToastCenter
    @State private var herdrStore: HerdrStore
    @State private var viewModel: SessionViewModel
    @State private var undoJournal: UndoJournal
    @State private var rearrangeMode = RearrangeMode()

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
        // One client, two roles: `HerdrClient` conforms to both
        // `HerdrCommandClient` and `LayoutExportClient`, so the view-model's
        // command verbs and the layout-export coordinator share the same
        // actor rather than opening a second one.
        let herdrClient = HerdrClient(socketPath: socketPath)
        _viewModel = State(initialValue: SessionViewModel(
            client: herdrClient,
            ghosttyFactory: ghosttyFactory,
            layoutExportClient: herdrClient,
            planExecutor: herdrStore,
            undoJournal: undoJournal,
            paneScrollSubscriber: paneScrollSubscriber,
            // Not an undo/redo notice -- an invalid move or a plan/herdr
            // failure from `perform`/`closePane` -- so this gets the
            // neutral info glyph, never the undo journal's arrow.
            noticeSink: { message in toastCenter.show(message, kind: .info) }
        ))
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
                .background(RearrangeControlMonitorHost(rearrangeMode: rearrangeMode))
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
            CommandGroup(after: .sidebar) {
                ThemeMenu(themeStore: themeStore)
                TerminalTextSizeMenu(store: terminalTextSizeStore)
                // No key equivalent: the momentary route into rearrange mode
                // is a held Control, not a shortcut on this item.
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
