import AppKit
import FlockCore

/// Keeps flock's window at the size and place it was left: across a quit and
/// relaunch, across a Cmd+W and reopen, and across a crash.
///
/// The frame is bound to a window's own lifetime rather than to the app's.
/// `applicationDidFinishLaunching` runs once per process and can run before
/// the SwiftUI window exists at all, so a restore hung off launch alone can
/// miss the first window and misses every later one by construction: the
/// window reopened after a Cmd+W is a different one, with no observers on it,
/// so its size is never even written down. Here every window that becomes
/// main is offered the saved frame and then carries its own save observers,
/// whenever in the process's life it was created.
@MainActor
final class MainWindowFrameKeeper {
    private weak var adopted: NSWindow?
    private var becameMainObserver: NSObjectProtocol?
    private var adoptedObservers: [NSObjectProtocol] = []

    /// Safe to call more than once: the app calls it both before and after
    /// launch finishes, since which of those runs before the first window
    /// exists is not something the app gets to know.
    func start() {
        if becameMainObserver == nil {
            becameMainObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification, object: nil, queue: nil
            ) { [weak self] notification in
                // Read out here rather than inside: a whole `Notification` is
                // not sendable, and the window it carries is.
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.adopt(window) }
            }
        }
        if let window = NSApp.windows.first(where: { Self.isFlockWindow($0) }) {
            adopt(window)
        }
    }

    /// The last word before the process ends. The frame is already written
    /// down after every resize and move, so this covers only a quit that
    /// follows neither.
    func save() {
        save(adopted)
    }

    /// flock's window is the app's content window: titled, closable and
    /// resizable. AppKit's own windows that can take main away from it (an
    /// alert, the About box) are panels, or answer to at least one of those
    /// differently, which is what keeps them from being adopted in its place.
    private static func isFlockWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        let style = window.styleMask
        return style.contains(.titled) && style.contains(.closable) && style.contains(.resizable)
    }

    private func adopt(_ window: NSWindow) {
        guard Self.isFlockWindow(window), adopted !== window else { return }
        release()
        adopted = window
        restore(into: window)
        observe(window)
    }

    private func restore(into window: NSWindow) {
        guard let frame = MainWindowFrame.restored(
            from: UserDefaults.standard.string(forKey: MainWindowFrame.defaultsKey),
            visibleScreenFrames: NSScreen.screens.map(\.visibleFrame)
        ) else { return }
        window.setFrame(frame, display: true)
    }

    /// Observed rather than saved at quit alone, so a crash or a force quit
    /// keeps the last live size.
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        adoptedObservers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            center.addObserver(forName: name, object: window, queue: nil) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.save(window) }
            }
        }
        adoptedObservers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    self?.save(window)
                    self?.release()
                }
            }
        )
    }

    /// A closed window is let go of entirely, so a window opened in its place
    /// is adopted fresh rather than mistaken for one already held.
    private func release() {
        for observer in adoptedObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        adoptedObservers = []
        adopted = nil
    }

    /// A full-screen window's frame is the whole display's, and restoring
    /// that would open an ordinary window the size of the screen; the last
    /// frame the window had of its own stands until it leaves full screen.
    private func save(_ window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(
            MainWindowFrame.encoded(window.frame), forKey: MainWindowFrame.defaultsKey
        )
    }
}
