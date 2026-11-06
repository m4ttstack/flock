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
            removeSuite: { removed.names.append($0) },
            machineSocketPath: { "/tmp/flock-501/dev-\($0.id.prefix(12))/herdr.sock" }
        )
    }

    private let mini = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
    private let studio = HerdrMachine(id: "fedcba9876543210fedcba9876543210", label: "acme-studio", target: "acme-studio", session: "default")

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

    func testSyncAddsMachineProfilesAfterUserProfiles() throws {
        let store = makeStore(makeDefaults())
        let demo = try XCTUnwrap(store.create(name: "Demo", socketPath: nil))
        store.syncMachines([mini, studio])
        XCTAssertEqual(store.profiles.map(\.id), ["default", demo.id, "machine.\(mini.id)", "machine.\(studio.id)"])
        XCTAssertEqual(store.profiles.map(\.name), ["Default", "Demo", "acme-mini", "acme-studio"])
        XCTAssertEqual(store.profiles[2].machine, mini)
        XCTAssertTrue(store.profiles[2].isMachine)
        XCTAssertFalse(store.profiles[0].isMachine)
        let later = try XCTUnwrap(store.create(name: "Later", socketPath: nil))
        XCTAssertEqual(store.profiles.map(\.id), ["default", demo.id, later.id, "machine.\(mini.id)", "machine.\(studio.id)"])
    }

    func testSyncRenamesInPlaceAndKeepsID() {
        let store = makeStore(makeDefaults())
        store.syncMachines([mini])
        var renamed = mini
        renamed.label = "acme-mac"
        store.syncMachines([renamed])
        XCTAssertEqual(store.profiles.map(\.id), ["default", "machine.\(mini.id)"])
        XCTAssertEqual(store.profiles[1].name, "acme-mac")
        XCTAssertEqual(store.profiles[1].machine?.label, "acme-mac")
    }

    func testSyncDropsRemovedMachineUnlessCurrent() {
        let store = makeStore(makeDefaults())
        store.syncMachines([mini, studio])
        store.select("machine.\(mini.id)")
        store.syncMachines([studio])
        XCTAssertEqual(store.profiles.map(\.id), ["default", "machine.\(mini.id)", "machine.\(studio.id)"])
        store.select("default")
        store.syncMachines([studio])
        XCTAssertEqual(store.profiles.map(\.id), ["default", "machine.\(studio.id)"])
    }

    func testStoredMachineStaysCurrentBeforeAnySync() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.syncMachines([mini])
        store.select("machine.\(mini.id)")
        let again = makeStore(defaults)
        XCTAssertEqual(again.currentID, "machine.\(mini.id)")
        XCTAssertEqual(again.current.machine, mini)
        XCTAssertFalse(again.currentMachineMissing)
    }

    func testMachineSocketPathComesFromInjectedClosure() {
        let store = makeStore(makeDefaults())
        store.syncMachines([mini])
        XCTAssertEqual(store.socketPath(of: store.profiles[1]), "/tmp/flock-501/dev-0123456789ab/herdr.sock")
        XCTAssertEqual(store.socketPath(of: store.profiles[0]), homeSocket)
    }

    func testMachineProfilesCannotBeRenamedOrDeleted() {
        let store = makeStore(makeDefaults())
        store.syncMachines([mini])
        let id = "machine.\(mini.id)"
        store.rename(id, to: "Other")
        XCTAssertEqual(store.profiles[1].name, "acme-mini")
        store.setSocket(acme, for: id)
        XCTAssertNil(store.profiles[1].socketPath)
        XCTAssertEqual(store.profiles[1].knownSockets, [])
        XCTAssertFalse(store.delete(id))
        XCTAssertEqual(store.profiles.count, 2)
    }

    func testProfilesStoredBeforeMachinesStillDecode() {
        let defaults = makeDefaults()
        let old = #"{"profiles":[{"id":"default","name":"Default","knownSockets":["\#(homeSocket)"]},{"id":"p1","name":"Demo","knownSockets":[]}],"currentID":"p1"}"#
        defaults.set(Data(old.utf8), forKey: ProfileStore.defaultsKey)
        let store = makeStore(defaults)
        XCTAssertEqual(store.profiles.map(\.id), ["default", "p1"])
        XCTAssertEqual(store.currentID, "p1")
        XCTAssertNil(store.profiles[1].machine)
        XCTAssertFalse(store.profiles[1].isMachine)
    }

    func testSyncFlagsCurrentMachineMissing() {
        let store = makeStore(makeDefaults())
        XCTAssertFalse(store.currentMachineMissing)
        store.syncMachines([mini])
        store.select("machine.\(mini.id)")
        store.syncMachines([mini])
        XCTAssertFalse(store.currentMachineMissing)
        store.syncMachines([studio])
        XCTAssertTrue(store.currentMachineMissing)
        store.syncMachines([mini, studio])
        XCTAssertFalse(store.currentMachineMissing)
        store.syncMachines([studio])
        store.select("default")
        XCTAssertFalse(store.currentMachineMissing)
    }

    func testDroppedMachineRemovesItsIdStateSuite() {
        let removed = Removed()
        let store = makeStore(makeDefaults(), removed: removed)
        store.syncMachines([mini, studio])
        store.syncMachines([studio])
        let expected = ProfileSuites.serverSuiteName(
            bundleID: "b",
            profileID: "machine.\(mini.id)",
            socketPath: "/tmp/flock-501/dev-0123456789ab/herdr.sock",
            defaultSocketPath: homeSocket
        )
        XCTAssertNotNil(expected)
        XCTAssertEqual(removed.names, [expected].compactMap { $0 })
    }
}
