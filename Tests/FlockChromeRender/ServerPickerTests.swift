import Darwin
import XCTest
@testable import FlockCore

@MainActor
final class ServerPickerTests: XCTestCase {
    private static let home = "/Users/someone"
    private static let defaultEntry = HerdrSessionEntry(
        name: "default", isRunning: true, socketPath: home + "/.config/herdr/herdr.sock", isDefault: true
    )
    private static let acmeEntry = HerdrSessionEntry(
        name: "acme", isRunning: false, socketPath: home + "/.config/herdr/sessions/acme/herdr.sock", isDefault: false
    )

    private var started: [String] = []
    private var chosen: [String?] = []
    private var startResult: Result<Void, HerdrServerLauncher.Failure> = .success(())

    private func makePicker() -> ServerPicker {
        ServerPicker(
            list: { [Self.defaultEntry, Self.acmeEntry] },
            start: { [unowned self] name in
                started.append(name)
                return startResult
            },
            choose: { [unowned self] socket in
                chosen.append(socket)
                return true
            },
            currentSocket: { Self.home + "/.config/herdr/herdr.sock" },
            isLocked: false,
            home: Self.home
        )
    }

    func testChoosingDefaultPassesNil() async {
        let picker = makePicker()
        await picker.choose(Self.defaultEntry)
        XCTAssertEqual(chosen, [nil])
    }

    func testChoosingANamedEntryPassesItsSocket() async {
        let picker = makePicker()
        await picker.choose(Self.acmeEntry)
        XCTAssertEqual(chosen, [Self.acmeEntry.socketPath])
    }

    func testStartNewStartsThenChoosesTheNewSocket() async {
        let picker = makePicker()
        await picker.startNew(name: "demo")
        XCTAssertEqual(started, ["demo"])
        XCTAssertEqual(chosen, ["/Users/someone/.config/herdr/sessions/demo/herdr.sock"])
        XCTAssertNil(picker.failure)
    }

    func testStartServerDoesNotChoose() async {
        let picker = makePicker()
        let socket = await picker.startServer(name: "demo")
        XCTAssertEqual(socket, "/Users/someone/.config/herdr/sessions/demo/herdr.sock")
        XCTAssertEqual(started, ["demo"])
        XCTAssertTrue(chosen.isEmpty)
    }

    func testStartNewRejectsABadNameWithoutStarting() async {
        let picker = makePicker()
        for name in ["a b", ".."] {
            await picker.startNew(name: name)
            XCTAssertEqual(
                picker.failure,
                "\"\(name)\" can't be a server name. Use letters, digits, \".\", \"_\" or \"-\".",
                name
            )
        }
        XCTAssertTrue(started.isEmpty)
        XCTAssertTrue(chosen.isEmpty)
    }

    func testTheReservedDefaultNameGetsItsOwnMessage() async {
        let picker = makePicker()
        await picker.startNew(name: "default")
        XCTAssertEqual(picker.failure, "\"default\" is herdr's own server. Pick another name.")
        let socket = await picker.startServer(name: "default")
        XCTAssertNil(socket)
        XCTAssertTrue(started.isEmpty)
        XCTAssertTrue(chosen.isEmpty)
    }

    func testANameListedAsRunningIsChosenWithoutStartingIt() async {
        let running = HerdrSessionEntry(
            name: "acme", isRunning: true, socketPath: Self.home + "/.config/herdr/sessions/acme/herdr.sock", isDefault: false
        )
        let picker = ServerPicker(
            list: { [Self.defaultEntry, running] },
            start: { [unowned self] name in
                started.append(name)
                return .failure(.notFound)
            },
            choose: { [unowned self] socket in
                chosen.append(socket)
                return true
            },
            currentSocket: { Self.home + "/.config/herdr/herdr.sock" },
            isLocked: false,
            home: Self.home
        )
        await picker.refresh()
        await picker.startNew(name: "acme")
        let socket = await picker.startServer(name: "acme")
        XCTAssertEqual(socket, running.socketPath)
        XCTAssertEqual(chosen, [running.socketPath])
        XCTAssertTrue(started.isEmpty)
        XCTAssertNil(picker.failure)
    }

    func testANameListedButStoppedIsStillStarted() async {
        let picker = makePicker()
        await picker.refresh()
        await picker.startNew(name: "acme")
        XCTAssertEqual(started, ["acme"])
    }

    func testARelativeCustomPathIsRejected() async {
        let picker = makePicker()
        for path in ["acme/x.sock", "./x.sock", "x.sock"] {
            await picker.chooseCustom(path: path)
            XCTAssertEqual(picker.failure, "Use a full path, starting with / or ~.", path)
        }
        XCTAssertTrue(chosen.isEmpty)
        await picker.chooseCustom(path: "/tmp/acme.sock")
        XCTAssertNil(picker.failure)
        XCTAssertEqual(chosen, ["/tmp/acme.sock"])
    }

    func testAStartFailureIsShownAndNothingIsChosen() async {
        let picker = makePicker()
        startResult = .failure(.notFound)
        await picker.startNew(name: "demo")
        XCTAssertEqual(picker.failure, "flock couldn't find herdr on its PATH.")
        startResult = .failure(.spawn(EACCES))
        let socket = await picker.startServer(name: "demo")
        XCTAssertNil(socket)
        XCTAssertEqual(picker.failure, "herdr wouldn't start (\(String(cString: strerror(EACCES)))).")
        XCTAssertTrue(chosen.isEmpty)
    }

    func testCustomPathsAreExpandedAndTheDefaultIsRecognised() async {
        let picker = makePicker()
        await picker.chooseCustom(path: "")
        await picker.chooseCustom(path: "~/.config/herdr/herdr.sock")
        await picker.chooseCustom(path: "~/acme/x.sock")
        XCTAssertEqual(chosen, [nil, "/Users/someone/acme/x.sock"])
    }

    func testRefreshListsEntriesAndMarksTheCurrentOne() async {
        let picker = makePicker()
        await picker.refresh()
        XCTAssertEqual(picker.entries, [Self.defaultEntry, Self.acmeEntry])
        XCTAssertTrue(picker.isCurrent(Self.defaultEntry))
        XCTAssertFalse(picker.isCurrent(Self.acmeEntry))
        XCTAssertNil(picker.lockedNote)
    }

    func testASecondStartWhileOneIsInFlightStartsNothing() async {
        var resume: CheckedContinuation<Void, Never>?
        var startCount = 0
        let picker = ServerPicker(
            list: { [] },
            start: { _ in
                startCount += 1
                return .success(())
            },
            choose: { _ in
                await withCheckedContinuation { resume = $0 }
                return true
            },
            currentSocket: { Self.home + "/.config/herdr/herdr.sock" },
            isLocked: false,
            home: Self.home
        )
        let first = Task { await picker.startNew(name: "demo") }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(picker.isBusy)
        await picker.startNew(name: "demo")
        let second = await picker.startServer(name: "demo")
        XCTAssertNil(second)
        XCTAssertEqual(startCount, 1)
        resume?.resume()
        await first.value
        XCTAssertFalse(picker.isBusy)
    }

    private static let buildEntry = HerdrSessionEntry(
        name: "build", isRunning: true, socketPath: home + "/.config/herdr/sessions/build/herdr.sock", isDefault: false
    )

    private var stopped: [String] = []
    private var deleted: [String] = []
    private var listCount = 0
    private var current = ServerPickerTests.defaultEntry.socketPath
    private var holder: String?

    private func makeControlPicker(
        stopResult: Result<Void, HerdrSessionControl.Failure> = .success(()),
        stopGate: (() async -> Void)? = nil
    ) -> ServerPicker {
        ServerPicker(
            list: { [unowned self] in
                listCount += 1
                return [Self.defaultEntry, Self.acmeEntry, Self.buildEntry]
            },
            start: { _ in .success(()) },
            choose: { _ in true },
            currentSocket: { [unowned self] in current },
            isLocked: false,
            home: Self.home,
            heldBy: { [unowned self] socket in socket == Self.buildEntry.socketPath ? holder : nil },
            stop: { [unowned self] name in
                stopped.append(name)
                await stopGate?()
                return stopResult
            },
            delete: { [unowned self] name in
                deleted.append(name)
                return .success(())
            }
        )
    }

    func testStopServerStopsByNameThenRefreshes() async {
        let picker = makeControlPicker()
        await picker.stopServer(name: "build")
        XCTAssertEqual(stopped, ["build"])
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(listCount, 2, "rechecked before, refreshed after")
        XCTAssertEqual(picker.entries, [Self.defaultEntry, Self.acmeEntry, Self.buildEntry])
        XCTAssertNil(picker.failure)
    }

    func testDeleteServerDeletesByNameThenRefreshes() async {
        let picker = makeControlPicker()
        await picker.deleteServer(name: "acme")
        XCTAssertEqual(deleted, ["acme"])
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(listCount, 2, "rechecked before, refreshed after")
        XCTAssertNil(picker.failure)
    }

    func testAFailedStopShowsHerdrsMessage() async {
        let picker = makeControlPicker(stopResult: .failure(.herdr("session build is not running")))
        await picker.stopServer(name: "build")
        XCTAssertEqual(picker.failure, "session build is not running")
        XCTAssertTrue(picker.failureIsFromServerList)
        await picker.deleteServer(name: "acme")
        XCTAssertNil(picker.failure)
    }

    func testStopIsRecheckedWhenThisFlockMovedOntoTheServer() async {
        let picker = makeControlPicker()
        await picker.refresh()
        XCTAssertEqual(picker.action(for: Self.buildEntry), .stop)
        current = Self.buildEntry.socketPath
        await picker.stopServer(name: "build")
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(picker.failure, "Didn't stop \"build\": This Flock is on it.")
        XCTAssertTrue(picker.failureIsFromServerList)
    }

    func testStopIsRecheckedWhenAnotherFlockTookTheServer() async {
        let picker = makeControlPicker()
        await picker.refresh()
        XCTAssertEqual(picker.action(for: Self.buildEntry), .stop)
        holder = "Flock Dev"
        await picker.stopServer(name: "build")
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(picker.failure, "Didn't stop \"build\": Open in Flock Dev.")
        XCTAssertEqual(picker.action(for: Self.buildEntry), .unavailable("Open in Flock Dev"))
    }

    func testTheWrongActionOrAVanishedServerSpawnsNothing() async {
        let picker = makeControlPicker()
        await picker.stopServer(name: "acme")
        XCTAssertEqual(picker.failure, "\"acme\" isn't running any more.")
        await picker.deleteServer(name: "build")
        XCTAssertEqual(picker.failure, "\"build\" is running again.")
        await picker.deleteServer(name: "gone")
        XCTAssertEqual(picker.failure, "\"gone\" isn't listed any more.")
        await picker.stopServer(name: "default")
        XCTAssertEqual(picker.failure, "Didn't stop \"default\": herdr's own server.")
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testStopWhileBusyDoesNothing() async {
        var resume: CheckedContinuation<Void, Never>?
        let picker = makeControlPicker(stopGate: { await withCheckedContinuation { resume = $0 } })
        let first = Task { await picker.stopServer(name: "build") }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(picker.isBusy)
        await picker.stopServer(name: "build")
        await picker.deleteServer(name: "acme")
        XCTAssertEqual(stopped, ["build"])
        XCTAssertTrue(deleted.isEmpty)
        resume?.resume()
        await first.value
        XCTAssertFalse(picker.isBusy)
    }

    func testALockedPickerNamesTheOverride() {
        let picker = ServerPicker(
            list: { [] }, start: { _ in .success(()) }, choose: { _ in true },
            currentSocket: { "/tmp/acme.sock" }, isLocked: true, home: Self.home
        )
        XCTAssertEqual(picker.lockedNote, "Set by HERDR_SOCKET_PATH: /tmp/acme.sock")
    }
}
