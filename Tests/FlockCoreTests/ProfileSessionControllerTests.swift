import XCTest
@testable import FlockCore

@MainActor
final class ProfileSessionControllerTests: XCTestCase {
    private let home = "/Users/someone/.config/herdr/herdr.sock"
    private let acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
    private let homeDirectory = "/Users/someone"
    private let runID = UUID().uuidString

    private final class Log {
        var lines: [String] = []
        var remote: [Bool] = []
    }

    private final class Gate {
        var armed = false
        var waiting: CheckedContinuation<Void, Never>?
    }

    private final class FakeSession: ProfileSession {
        let socketPath: String
        let log: Log
        let gate: Gate

        init(socketPath: String, log: Log, gate: Gate) {
            self.socketPath = socketPath
            self.log = log
            self.gate = gate
        }

        func start() async {
            log.lines.append("start \(socketPath)")
        }

        func shutdown() async {
            log.lines.append("shutdown \(socketPath)")
            if gate.armed {
                gate.armed = false
                await withCheckedContinuation { gate.waiting = $0 }
            }
        }
    }

    private struct Fixture {
        let log: Log
        let gate: Gate
        let store: ProfileStore
        let p1: FlockProfile
    }

    private func makeFixture() throws -> Fixture {
        let name = "psc-store-\(runID)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let store = ProfileStore(
            userDefaults: UserDefaults(suiteName: name)!,
            bundleID: "b",
            defaultSocketPath: home,
            home: homeDirectory,
            removeSuite: { _ in },
            machineSocketPath: { "/tmp/flock-501/dev-\($0.id.prefix(12))/herdr.sock" }
        )
        let p1 = try XCTUnwrap(store.create(name: "P1", socketPath: acme))
        return Fixture(log: Log(), gate: Gate(), store: store, p1: p1)
    }

    private func makeController(
        _ fixture: Fixture,
        socketOverride: String? = nil,
        confirm: Bool = true
    ) -> ProfileSessionController<FakeSession> {
        makeController(fixture, socketOverride: socketOverride, confirm: { confirm })
    }

    private func makeController(
        _ fixture: Fixture,
        socketOverride: String? = nil,
        confirm: @escaping () -> Bool
    ) -> ProfileSessionController<FakeSession> {
        let log = fixture.log
        let gate = fixture.gate
        let runID = runID
        let environment = ProfileSessionEnvironment<FakeSession>(
            bundleID: "b",
            defaultSocketPath: home,
            home: homeDirectory,
            socketOverride: socketOverride,
            defaults: { [unowned self] name in
                log.lines.append("suite \(name ?? "standard")")
                let full = "psc-\(runID)-\(name ?? "standard")"
                addTeardownBlock { UserDefaults().removePersistentDomain(forName: full) }
                return UserDefaults(suiteName: full)!
            },
            confirmAttach: { key, target, stay in
                log.lines.append("confirm \(key) \(target) \(stay)")
                return confirm()
            },
            register: { log.lines.append("register \($0)") },
            setChildSocket: { log.lines.append("child \($0 ?? "nil")") },
            make: { context in
                log.lines.append("make \(context.profile.id) \(context.socketPath)")
                log.remote.append(context.isRemoteMachine)
                return FakeSession(socketPath: context.socketPath, log: log, gate: gate)
            }
        )
        return ProfileSessionController(profiles: fixture.store, environment: environment)
    }

    private let machine = HerdrMachine(
        id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default"
    )

    func testSwitchToMachineClearsChildSocketAndConfirmsByMachineKey() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        let controller = makeController(fixture)
        let tunnel = "/tmp/flock-501/dev-0123456789ab/herdr.sock"
        fixture.log.lines.removeAll()
        let switched = await controller.switchTo(profileID: "machine.\(machine.id)")
        XCTAssertTrue(switched)
        XCTAssertEqual(fixture.log.lines, [
            "confirm herdr-machine:\(machine.id) acme-mini Default",
            "shutdown \(home)",
            "child nil",
            "suite standard",
            "suite b.profile.machine.\(machine.id).server.\(ProfileSuites.socketKey(tunnel))",
            "make machine.\(machine.id) \(tunnel)",
            "register herdr-machine:\(machine.id)",
            "start \(tunnel)",
        ])
        XCTAssertEqual(controller.attachKey, "herdr-machine:\(machine.id)")
        XCTAssertEqual(controller.socketPath, tunnel)
        XCTAssertEqual(fixture.log.remote, [false, true])
    }

    func testAMachineListDroppingTheTargetMidSwitchStillLandsOnIt() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        let controller = makeController(fixture)
        let tunnel = "/tmp/flock-501/dev-0123456789ab/herdr.sock"
        let id = "machine.\(machine.id)"
        fixture.gate.armed = true

        let switched = Task { await controller.switchTo(profileID: id) }
        while fixture.gate.waiting == nil { await Task.yield() }
        fixture.store.syncMachines([])
        XCTAssertTrue(fixture.store.profiles.contains { $0.id == id }, "held while the switch is in flight")
        fixture.gate.waiting?.resume()
        let result = await switched.value

        XCTAssertTrue(result)
        XCTAssertEqual(fixture.store.currentID, id)
        XCTAssertEqual(controller.session.socketPath, tunnel)
        XCTAssertEqual(fixture.log.lines.last(where: { $0.hasPrefix("make ") }), "make \(id) \(tunnel)")
        XCTAssertEqual(controller.attachKey, "herdr-machine:\(machine.id)")
        XCTAssertTrue(fixture.store.currentMachineMissing)
    }

    func testARefusedSwitchReleasesItsTarget() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        let controller = makeController(fixture, confirm: false)
        await controller.switchTo(profileID: "machine.\(machine.id)")
        fixture.store.syncMachines([])
        XCTAssertFalse(fixture.store.profiles.contains { $0.isMachine })
    }

    func testAProfileCannotBeDeletedWhileASwitchMovesOntoIt() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        fixture.gate.armed = true

        let switched = Task { await controller.switchTo(profileID: fixture.p1.id) }
        while fixture.gate.waiting == nil { await Task.yield() }
        XCTAssertFalse(fixture.store.delete(fixture.p1.id))
        fixture.gate.waiting?.resume()
        _ = await switched.value

        XCTAssertEqual(fixture.store.currentID, fixture.p1.id)
        XCTAssertEqual(controller.socketPath, acme)
    }

    func testAnOverrideRunsAMachineProfileAsAPlainSocketSession() throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        fixture.store.select("machine.\(machine.id)")
        let controller = makeController(fixture, socketOverride: "/tmp/acme/x.sock")
        XCTAssertEqual(fixture.log.lines, [
            "child /tmp/acme/x.sock",
            "suite standard",
            "suite b.override",
            "make machine.\(machine.id) /tmp/acme/x.sock",
        ])
        XCTAssertEqual(fixture.log.remote, [false])
        XCTAssertEqual(controller.attachKey, "/tmp/acme/x.sock")
        XCTAssertEqual(controller.socketPath, "/tmp/acme/x.sock")
    }

    func testSwitchingBackFromAMachineRestoresTheChildSocket() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        let controller = makeController(fixture)
        await controller.switchTo(profileID: "machine.\(machine.id)")
        fixture.log.lines.removeAll()
        await controller.switchTo(profileID: "default")
        XCTAssertTrue(fixture.log.lines.contains("child \(home)"))
        XCTAssertEqual(controller.attachKey, home)
    }

    func testAMachineProfileCannotChangeServer() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        fixture.store.select("machine.\(machine.id)")
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        let changed = await controller.changeServer(to: acme)
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.log.lines, [])
    }

    func testMachineIdStateIsItsOwnSuite() async throws {
        let fixture = try makeFixture()
        fixture.store.syncMachines([machine])
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        await controller.switchTo(profileID: "machine.\(machine.id)")
        let suites = fixture.log.lines.filter { $0.hasPrefix("suite ") }
        XCTAssertEqual(suites.count, 2)
        XCTAssertEqual(suites.first, "suite standard")
        XCTAssertTrue(suites.last?.hasPrefix("suite b.profile.machine.\(machine.id).server.") == true)
    }

    func testLaunchBuildsTheCurrentProfileOnItsSocketAndStartsNothing() throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        XCTAssertEqual(fixture.log.lines, ["child \(home)", "suite standard", "suite standard", "make default \(home)"])
        XCTAssertEqual(controller.generation, 0)
        XCTAssertEqual(controller.socketPath, home)
        XCTAssertFalse(controller.isLocked)
    }

    func testASwitchRunsInOrder() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        let switched = await controller.switchTo(profileID: fixture.p1.id)
        XCTAssertTrue(switched)
        XCTAssertEqual(fixture.log.lines, [
            "confirm \(acme) acme Default",
            "shutdown \(home)",
            "child \(acme)",
            "suite b.profile.\(fixture.p1.id)",
            "suite b.profile.\(fixture.p1.id).server.\(ProfileSuites.socketKey(acme))",
            "make \(fixture.p1.id) \(acme)",
            "register \(acme)",
            "start \(acme)",
        ])
        XCTAssertEqual(controller.generation, 1)
        XCTAssertEqual(fixture.store.currentID, fixture.p1.id)
        XCTAssertEqual(controller.socketPath, acme)
        XCTAssertEqual(controller.session.socketPath, acme)
    }

    func testARefusedSwitchSavesNothing() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture, confirm: false)
        let before = fixture.store.profiles
        fixture.log.lines.removeAll()
        let switched = await controller.switchTo(profileID: fixture.p1.id)
        let changed = await controller.changeServer(to: acme)
        XCTAssertFalse(switched)
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.log.lines, ["confirm \(acme) acme Default", "confirm \(acme) acme default"])
        XCTAssertEqual(fixture.store.currentID, "default")
        XCTAssertEqual(fixture.store.profiles, before)
        XCTAssertEqual(controller.generation, 0)
    }

    func testChangingServerKeepsTheProfileAndRemembersBothServers() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        let changed = await controller.changeServer(to: acme)
        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.log.lines, [
            "confirm \(acme) acme default",
            "shutdown \(home)",
            "child \(acme)",
            "suite standard",
            "suite b.profile.default.server.\(ProfileSuites.socketKey(acme))",
            "make default \(acme)",
            "register \(acme)",
            "start \(acme)",
        ])
        XCTAssertEqual(fixture.store.currentID, "default")
        XCTAssertEqual(fixture.store.current.knownSockets, [home, acme])
        XCTAssertEqual(fixture.store.current.socketPath, acme)
        XCTAssertEqual(controller.generation, 1)
    }

    func testChangingBackToTheDefaultSocketStoresNil() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        await controller.changeServer(to: acme)
        fixture.log.lines.removeAll()
        let changed = await controller.changeServer(to: "~/.config/herdr/./herdr.sock")
        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.log.lines.first, "confirm \(home) default acme")
        XCTAssertNil(fixture.store.current.socketPath)
        XCTAssertEqual(fixture.log.lines.last, "start \(home)")
    }

    func testOverrideUsesTheOverrideSuiteAndLocks() async throws {
        let fixture = try makeFixture()
        let before = fixture.store.profiles
        let controller = makeController(fixture, socketOverride: "/tmp/acme/x.sock")
        XCTAssertEqual(fixture.log.lines, ["child /tmp/acme/x.sock", "suite standard", "suite b.override", "make default /tmp/acme/x.sock"])
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.socketPath, "/tmp/acme/x.sock")
        fixture.log.lines.removeAll()
        let switched = await controller.switchTo(profileID: fixture.p1.id)
        let changed = await controller.changeServer(to: acme)
        XCTAssertFalse(switched)
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.log.lines, [])
        XCTAssertEqual(fixture.store.profiles, before)
        XCTAssertEqual(fixture.store.currentID, "default")
    }

    func testSwitchingToWhereYouAreDoesNothing() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        let switched = await controller.switchTo(profileID: "default")
        let changed = await controller.changeServer(to: nil)
        XCTAssertFalse(switched)
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.log.lines, [])
        XCTAssertEqual(controller.generation, 0)
    }

    func testTheTargetIsInFlightDuringShutdownForASwitchAndAServerChange() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        XCTAssertNil(controller.switchingTo)

        fixture.gate.armed = true
        let switched = Task { await controller.switchTo(profileID: fixture.p1.id) }
        while fixture.gate.waiting == nil { await Task.yield() }
        XCTAssertEqual(controller.switchingTo, acme)
        XCTAssertEqual(controller.switchingToProfile?.id, fixture.p1.id)
        fixture.gate.waiting?.resume()
        fixture.gate.waiting = nil
        let switchResult = await switched.value
        XCTAssertTrue(switchResult)
        XCTAssertNil(controller.switchingTo)
        XCTAssertNil(controller.switchingToProfile)

        fixture.gate.armed = true
        let changed = Task { await controller.changeServer(to: "~/.config/herdr/herdr.sock") }
        while fixture.gate.waiting == nil { await Task.yield() }
        XCTAssertEqual(controller.switchingTo, home)
        XCTAssertNil(controller.switchingToProfile, "a server change is not a profile switch")
        fixture.gate.waiting?.resume()
        let changeResult = await changed.value
        XCTAssertTrue(changeResult)
        XCTAssertNil(controller.switchingTo)
    }

    func testAServerChangeIsNamedAsOneUntilTheNextProfileSwitch() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture)
        XCTAssertFalse(controller.lastChangeWasServer)

        fixture.gate.armed = true
        let changed = Task { await controller.changeServer(to: acme) }
        while fixture.gate.waiting == nil { await Task.yield() }
        XCTAssertEqual(controller.switchingToServer, acme)
        XCTAssertTrue(controller.lastChangeWasServer)
        fixture.gate.waiting?.resume()
        fixture.gate.waiting = nil
        _ = await changed.value
        XCTAssertNil(controller.switchingToServer)
        XCTAssertTrue(controller.lastChangeWasServer, "kept after the rebuild, so the loader keeps the server's name")

        fixture.gate.armed = true
        let switched = Task { await controller.switchTo(profileID: fixture.p1.id) }
        while fixture.gate.waiting == nil { await Task.yield() }
        XCTAssertNil(controller.switchingToServer, "a profile switch is not a server change")
        XCTAssertFalse(controller.lastChangeWasServer)
        fixture.gate.waiting?.resume()
        _ = await switched.value
    }

    func testARefusedChangeKeepsTheLastChangesKind() async throws {
        let fixture = try makeFixture()
        let refusing = makeController(fixture, confirm: false)
        await refusing.changeServer(to: acme)
        XCTAssertFalse(refusing.lastChangeWasServer, "a refused server change is not one")

        var confirm = true
        let controller = makeController(fixture, confirm: { confirm })
        let changed = await controller.changeServer(to: acme)
        XCTAssertTrue(changed)
        XCTAssertTrue(controller.lastChangeWasServer)
        confirm = false
        let refusedServer = await controller.changeServer(to: home)
        let refusedProfile = await controller.switchTo(profileID: fixture.p1.id)
        XCTAssertFalse(refusedServer)
        XCTAssertFalse(refusedProfile)
        XCTAssertTrue(controller.lastChangeWasServer, "refusals leave the last confirmed change's kind")
    }

    func testARefusedSwitchLeavesNothingInFlight() async throws {
        let fixture = try makeFixture()
        let controller = makeController(fixture, confirm: false)
        await controller.switchTo(profileID: fixture.p1.id)
        await controller.changeServer(to: acme)
        XCTAssertNil(controller.switchingTo)
        XCTAssertNil(controller.switchingToProfile)
    }

    func testASwitchRequestedMidSwitchWaitsItsTurn() async throws {
        let fixture = try makeFixture()
        let p2 = try XCTUnwrap(fixture.store.create(name: "P2", socketPath: nil))
        let controller = makeController(fixture)
        fixture.log.lines.removeAll()
        fixture.gate.armed = true

        let first = Task { await controller.switchTo(profileID: fixture.p1.id) }
        while fixture.gate.waiting == nil { await Task.yield() }
        let second = Task { await controller.switchTo(profileID: p2.id) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(fixture.log.lines, ["confirm \(acme) acme Default", "shutdown \(home)"])

        fixture.gate.waiting?.resume()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)

        let lines = fixture.log.lines
        let firstStart = try XCTUnwrap(lines.firstIndex(of: "start \(acme)"))
        let secondConfirm = try XCTUnwrap(lines.firstIndex(of: "confirm \(home) default P1"))
        XCTAssertLessThan(firstStart, secondConfirm)
        XCTAssertEqual(lines.last, "start \(home)")
        let makes = lines.indices.filter { lines[$0].hasPrefix("make ") }
        let starts = lines.indices.filter { lines[$0].hasPrefix("start ") }
        XCTAssertEqual(makes.count, 2)
        XCTAssertEqual(starts.count, 2)
        for (make, start) in zip(makes, starts) {
            XCTAssertLessThan(make, start)
        }
        XCTAssertLessThan(starts[0], makes[1])
        XCTAssertEqual(controller.generation, 2)
        XCTAssertEqual(fixture.store.currentID, p2.id)
    }
}
