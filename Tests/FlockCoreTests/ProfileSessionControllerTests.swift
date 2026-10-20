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
            removeSuite: { _ in }
        )
        let p1 = try XCTUnwrap(store.create(name: "P1", socketPath: acme))
        return Fixture(log: Log(), gate: Gate(), store: store, p1: p1)
    }

    private func makeController(
        _ fixture: Fixture,
        socketOverride: String? = nil,
        confirm: Bool = true
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
            confirmAttach: { socket, label in
                log.lines.append("confirm \(socket) \(label)")
                return confirm
            },
            register: { log.lines.append("register \($0)") },
            setChildSocket: { log.lines.append("child \($0)") },
            make: { context in
                log.lines.append("make \(context.profile.id) \(context.socketPath)")
                return FakeSession(socketPath: context.socketPath, log: log, gate: gate)
            }
        )
        return ProfileSessionController(profiles: fixture.store, environment: environment)
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
            "confirm \(acme) Default",
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
        XCTAssertEqual(fixture.log.lines, ["confirm \(acme) Default", "confirm \(acme) default"])
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
            "confirm \(acme) default",
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
        XCTAssertEqual(fixture.log.lines.first, "confirm \(home) acme")
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
        XCTAssertEqual(fixture.log.lines, ["confirm \(acme) Default", "shutdown \(home)"])

        fixture.gate.waiting?.resume()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)

        let lines = fixture.log.lines
        let firstStart = try XCTUnwrap(lines.firstIndex(of: "start \(acme)"))
        let secondConfirm = try XCTUnwrap(lines.firstIndex(of: "confirm \(home) P1"))
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
