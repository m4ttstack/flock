import XCTest
@testable import FlockCore

@MainActor
final class ProfileStoreTests: XCTestCase {
    private let homeSocket = "/Users/someone/.config/herdr/herdr.sock"
    private let acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
    private let homeDirectory = "/Users/someone"

    private final class Removed {
        var names: [String] = []
    }

    private func makeStore(_ defaults: UserDefaults, removed: Removed = Removed()) -> ProfileStore {
        ProfileStore(
            userDefaults: defaults,
            bundleID: "b",
            defaultSocketPath: homeSocket,
            home: homeDirectory,
            removeSuite: { removed.names.append($0) }
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "profile-store-\(UUID())")!
    }

    func testNothingStoredIsOneDefaultProfile() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        XCTAssertEqual(store.profiles, [FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: [homeSocket])])
        XCTAssertEqual(store.currentID, "default")
        XCTAssertNil(defaults.object(forKey: ProfileStore.defaultsKey))
    }

    func testCreateRejectsABlankName() {
        let store = makeStore(makeDefaults())
        XCTAssertNil(store.create(name: "  ", socketPath: nil))
        let made = store.create(name: " Demo ", socketPath: "~/.config/herdr/sessions/acme/herdr.sock")
        XCTAssertEqual(made?.name, "Demo")
        XCTAssertEqual(made?.socketPath, acme)
        XCTAssertEqual(made?.knownSockets, [acme])
    }

    func testChangesPersistAcrossInstances() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        let made = try XCTUnwrap(store.create(name: "Demo", socketPath: nil))
        store.rename(made.id, to: "Renamed")
        store.setSocket(acme, for: made.id)
        store.select(made.id)
        let again = makeStore(defaults)
        XCTAssertEqual(again.profiles, store.profiles)
        XCTAssertEqual(again.currentID, made.id)
        XCTAssertEqual(again.current.name, "Renamed")
    }

    func testSetSocketRecordsEachServerOnce() {
        let store = makeStore(makeDefaults())
        store.setSocket(acme, for: "default")
        store.setSocket(nil, for: "default")
        store.setSocket(acme, for: "default")
        XCTAssertEqual(store.current.knownSockets, [homeSocket, acme])
        XCTAssertEqual(store.current.socketPath, acme)
    }

    func testDeleteRemovesEverySuiteAndNothingElse() throws {
        let removed = Removed()
        let store = makeStore(makeDefaults(), removed: removed)
        let made = try XCTUnwrap(store.create(name: "Demo", socketPath: acme))
        store.setSocket(nil, for: made.id)
        XCTAssertTrue(store.delete(made.id))
        XCTAssertEqual(removed.names, [
            "b.profile.\(made.id)",
            "b.profile.\(made.id).server.\(ProfileSuites.socketKey(acme))",
            "b.profile.\(made.id).server.\(ProfileSuites.socketKey(homeSocket))",
        ])
        XCTAssertFalse(store.profiles.contains { $0.id == made.id })
    }

    func testDefaultAndCurrentCannotBeDeleted() throws {
        let removed = Removed()
        let store = makeStore(makeDefaults(), removed: removed)
        let made = try XCTUnwrap(store.create(name: "Demo", socketPath: nil))
        store.select(made.id)
        XCTAssertFalse(store.delete("default"))
        XCTAssertFalse(store.delete(made.id))
        XCTAssertEqual(removed.names, [])
    }
}
