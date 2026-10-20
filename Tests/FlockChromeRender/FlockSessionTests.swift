import AppKit
import FlockCore
import SwiftUI
import XCTest

@MainActor
final class FlockSessionTests: XCTestCase {
    func testPreferencesAndIdStateLandInTheirOwnSuites() {
        let preferencesSuite = "fs-prefs-\(UUID())"
        let idStateSuite = "fs-ids-\(UUID())"
        let preferences = UserDefaults(suiteName: preferencesSuite)!
        let idState = UserDefaults(suiteName: idStateSuite)!
        defer {
            preferences.removePersistentDomain(forName: preferencesSuite)
            idState.removePersistentDomain(forName: idStateSuite)
        }
        preferences.set("one-light", forKey: ThemeStore.defaultsKey)
        let socket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
        let session = FlockSession(
            context: ProfileSessionContext(
                profile: FlockProfile(id: "p1", name: "Acme", socketPath: socket, knownSockets: [socket]),
                socketPath: socket, preferences: preferences, idState: idState
            ),
            ghosttyHost: nil,
            board: BoardStore(sources: BoardSources(readSetting: { nil }, fetchLogo: { nil }), userDefaults: idState),
            herdProgress: HerdProgressStore(sources: HerdProgressSources(listHerds: { nil }, readStatus: { _ in nil })),
            resnapshotInterval: nil, home: "/Users/someone"
        )
        XCTAssertEqual(session.address, .named("acme"))
        XCTAssertEqual(session.themeStore.active.id, "one-light")
        session.workspaceIdentityStore.setOverride(WorkspaceSymbols.all[0].name, for: "w1")
        XCTAssertNotNil(idState.data(forKey: WorkspaceIdentityStore.defaultsKey))
        XCTAssertNil(preferences.data(forKey: WorkspaceIdentityStore.defaultsKey))
    }

    func testShutdownRemovesAppWideMonitorsAndLetsTheSessionGo() async {
        let suite = "fs-teardown-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let socket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
        var session: FlockSession? = FlockSession(
            context: ProfileSessionContext(
                profile: FlockProfile(id: "p1", name: "Acme", socketPath: socket, knownSockets: [socket]),
                socketPath: socket, preferences: defaults, idState: defaults
            ),
            ghosttyHost: nil,
            board: BoardStore(sources: BoardSources(readSetting: { nil }, fetchLogo: { nil }), userDefaults: defaults),
            herdProgress: HerdProgressStore(sources: HerdProgressSources(listHerds: { nil }, readStatus: { _ in nil })),
            resnapshotInterval: nil, home: "/Users/someone"
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        session?.rearrangeMode.attach(to: window)
        XCTAssertTrue(session?.dragCoordinator.monitorsScrollWheel ?? false)
        XCTAssertTrue(session?.rearrangeMode.monitorsEscape ?? false)

        await session?.shutdown()
        XCTAssertFalse(session?.dragCoordinator.monitorsScrollWheel ?? true)
        XCTAssertFalse(session?.rearrangeMode.monitorsEscape ?? true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        session?.rearrangeMode.attach(to: other)
        XCTAssertFalse(session?.rearrangeMode.monitorsEscape ?? true)

        weak var weakSession = session
        weak var weakDrag = session?.dragCoordinator
        weak var weakRearrange = session?.rearrangeMode
        session = nil
        XCTAssertNil(weakSession)
        XCTAssertNil(weakDrag)
        XCTAssertNil(weakRearrange)
    }

    /// Whatever a view hands the terminal, a detached surface's session goes,
    /// and its bridge with it.
    func testADetachedSurfaceLetsItsTerminalGoWhateverItsLinkLookupHolds() async throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        weak var terminal: GhosttySession?
        do {
            let handle = GhosttySessionSurfaceHandle(session: host.makeSession(
                paneID: PaneID(rawValue: "w1:p1"),
                configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
            ))
            handle.session.linkFolder = { [handle] in
                _ = handle
                return nil
            }
            terminal = handle.session
            await handle.detach()
        }
        XCTAssertNil(terminal)
    }

    /// SwiftUI can still update a cell's terminal after its surface is
    /// detached, before the hierarchy goes.
    func testADetachedSurfaceTakesNoLinkLookupFromALaterUpdate() async throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let handle = GhosttySessionSurfaceHandle(session: host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
        ))
        func terminal(folder: String) -> GhosttyPaneTerminalView {
            GhosttyPaneTerminalView(
                surface: handle, grid: PTYSize(cols: 80, rows: 24), theme: .tokyoNight, isFocused: false,
                fontSizePoints: 13, optionAsAlt: .left, linkFolder: { folder }
            )
        }
        let hosting = NSHostingView(rootView: terminal(folder: "/acme/one"))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(handle.session.linkFolder?(), "/acme/one", "the terminal never installed its lookup")

        await handle.detach()
        hosting.rootView = terminal(folder: "/acme/two")
        hosting.layoutSubtreeIfNeeded()

        XCTAssertNil(handle.session.linkFolder)
    }
}
