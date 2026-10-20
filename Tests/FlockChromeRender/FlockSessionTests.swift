import FlockCore
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
}
