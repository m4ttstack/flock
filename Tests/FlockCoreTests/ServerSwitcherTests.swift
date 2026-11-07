import XCTest
@testable import FlockCore

@MainActor
final class ServerSwitcherTests: XCTestCase {
    private nonisolated static let suite = "ServerSwitcherTests"
    private nonisolated static let otherSuite = "ServerSwitcherTests.acme-work"
    private static let home = "/Users/acme"
    private static let defaultSocket = "/Users/acme/.config/herdr/herdr.sock"
    private static let workSocket = "/Users/acme/.config/herdr/sessions/acme-work/herdr.sock"
    private static let buildSocket = "/Users/acme/.config/herdr/sessions/acme-build/herdr.sock"
    private static let entries = [
        HerdrSessionEntry(name: "default", isRunning: true, socketPath: defaultSocket, isDefault: true),
        HerdrSessionEntry(name: "acme-work", isRunning: true, socketPath: workSocket, isDefault: false),
        HerdrSessionEntry(name: "acme-build", isRunning: false, socketPath: buildSocket, isDefault: false),
    ]

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        UserDefaults().removePersistentDomain(forName: Self.otherSuite)
        super.tearDown()
    }

    private func makeSwitcher(_ suite: String = suite) -> ServerSwitcher {
        ServerSwitcher(userDefaults: UserDefaults(suiteName: suite)!)
    }

    private func id(_ socket: String) -> ServerID { ServerID(socketPath: socket, home: Self.home) }

    private func candidates(current: String = defaultSocket, canChange: Bool = true) -> [ServerID] {
        ServerSwitcher.candidates(Self.entries, currentSocket: current, home: Self.home, canChangeServer: canChange)
    }

    func testCandidatesFollowTheServerMenuIncludingStoppedServers() {
        XCTAssertEqual(candidates(), [id(Self.defaultSocket), id(Self.workSocket), id(Self.buildSocket)])
    }

    func testACurrentSocketHerdrDoesNotListIsStillOffered() {
        let custom = "/tmp/acme/herdr.sock"
        XCTAssertEqual(candidates(current: custom).last, id(custom))
        let switcher = makeSwitcher()
        XCTAssertTrue(switcher.begin(items: candidates(current: custom), current: id(custom)))
        XCTAssertEqual(switcher.order.first, id(custom), "the first row is where the switch started")
    }

    func testSocketsAreComparedNormalized() {
        XCTAssertEqual(ServerID(socketPath: "~/.config/herdr/./herdr.sock", home: Self.home), id(Self.defaultSocket))
        XCTAssertEqual(candidates(current: "~/.config/herdr/herdr.sock").count, 3, "the current default is not added twice")
    }

    func testAnUnreadListAMachineOrALockedWindowOffersNothing() {
        XCTAssertEqual(
            ServerSwitcher.candidates(nil, currentSocket: Self.defaultSocket, home: Self.home, canChangeServer: true), []
        )
        XCTAssertEqual(candidates(canChange: false), [])
        let switcher = makeSwitcher()
        let begin = { (reverse: Bool) in
            switcher.begin(items: self.candidates(canChange: false), current: self.id(Self.defaultSocket), reverse: reverse)
        }
        XCTAssertFalse(switcher.apply(.next, begin: begin, open: {}), "⌥` goes to the terminal")
        XCTAssertFalse(switcher.isActive)
    }

    func testOneServerHasNothingToSwitchTo() {
        let switcher = makeSwitcher()
        let one = ServerSwitcher.candidates(
            Array(Self.entries.prefix(1)), currentSocket: Self.defaultSocket, home: Self.home, canChangeServer: true
        )
        XCTAssertFalse(switcher.apply(.next, begin: { switcher.begin(items: one, current: self.id(Self.defaultSocket), reverse: $0) }, open: {}))
        XCTAssertFalse(switcher.isActive)
    }

    func testATapFlipsToThePreviousServer() {
        let switcher = makeSwitcher()
        switcher.note(currentSocket: Self.workSocket, home: Self.home)
        switcher.note(currentSocket: Self.defaultSocket, home: Self.home)
        XCTAssertTrue(switcher.begin(items: candidates(), current: id(Self.defaultSocket)))
        XCTAssertEqual(switcher.order, [id(Self.defaultSocket), id(Self.workSocket), id(Self.buildSocket)])
        XCTAssertEqual(switcher.finish(), id(Self.workSocket))

        switcher.note(currentSocket: Self.workSocket, home: Self.home)
        XCTAssertTrue(switcher.begin(items: candidates(current: Self.workSocket), current: id(Self.workSocket)))
        XCTAssertEqual(switcher.finish(), id(Self.defaultSocket), "a second tap goes back")
    }

    func testRunningServersComeAheadOfStoppedOnes() {
        let docsSocket = "/Users/acme/.config/herdr/sessions/acme-docs/herdr.sock"
        let entries = Self.entries + [HerdrSessionEntry(name: "acme-docs", isRunning: true, socketPath: docsSocket, isDefault: false)]
        let switcher = makeSwitcher()
        switcher.note(currentSocket: Self.workSocket, home: Self.home)
        switcher.note(currentSocket: Self.buildSocket, home: Self.home)
        switcher.note(currentSocket: Self.defaultSocket, home: Self.home)
        let items = ServerSwitcher.candidates(entries, currentSocket: Self.defaultSocket, home: Self.home, canChangeServer: true)
        let stopped = ServerSwitcher.stopped(entries, home: Self.home)
        XCTAssertEqual(stopped, [id(Self.buildSocket)])
        XCTAssertTrue(switcher.begin(items: items, current: id(Self.defaultSocket), last: stopped))
        XCTAssertEqual(
            switcher.order, [id(Self.defaultSocket), id(Self.workSocket), id(docsSocket), id(Self.buildSocket)],
            "current, recent running, other running, then stopped"
        )
        XCTAssertEqual(switcher.finish(), id(Self.workSocket), "a tap skips the more recent stopped server")
    }

    func testAStoppedServerIsReachedWhenNothingElseRuns() {
        let entries = [Self.entries[0], Self.entries[2]]
        let switcher = makeSwitcher()
        XCTAssertTrue(switcher.begin(
            items: ServerSwitcher.candidates(entries, currentSocket: Self.defaultSocket, home: Self.home, canChangeServer: true),
            current: id(Self.defaultSocket), last: ServerSwitcher.stopped(entries, home: Self.home)
        ))
        XCTAssertEqual(switcher.finish(), id(Self.buildSocket))
    }

    func testAStoppedCurrentServerStaysFirst() {
        let switcher = makeSwitcher()
        XCTAssertTrue(switcher.begin(
            items: candidates(current: Self.buildSocket), current: id(Self.buildSocket),
            last: ServerSwitcher.stopped(Self.entries, home: Self.home)
        ))
        XCTAssertEqual(switcher.order.first, id(Self.buildSocket))
    }

    func testRecentsBelongToTheProfileTheyWereUsedIn() {
        let defaultProfile = makeSwitcher()
        defaultProfile.note(currentSocket: Self.buildSocket, home: Self.home)
        defaultProfile.note(currentSocket: Self.defaultSocket, home: Self.home)
        let work = makeSwitcher(Self.otherSuite)
        work.note(currentSocket: Self.workSocket, home: Self.home)

        XCTAssertEqual(
            UserDefaults(suiteName: Self.suite)!.stringArray(forKey: "flock.serverRecents"),
            [Self.defaultSocket, Self.buildSocket]
        )
        XCTAssertEqual(makeSwitcher().recents, [id(Self.defaultSocket), id(Self.buildSocket)], "survives a rebuild")
        XCTAssertEqual(makeSwitcher(Self.otherSuite).recents, [id(Self.workSocket)])
    }

    func testRowsAreNamedAsTheServerMenuNamesThem() {
        let current = ServerSwitcherRow.make(id(Self.defaultSocket), entries: Self.entries, currentSocket: Self.defaultSocket, home: Self.home)
        XCTAssertEqual(current, ServerSwitcherRow(label: "default", status: "running", isCurrent: true))
        let stopped = ServerSwitcherRow.make(id(Self.buildSocket), entries: Self.entries, currentSocket: Self.defaultSocket, home: Self.home)
        XCTAssertEqual(stopped, ServerSwitcherRow(label: "acme-build", status: "stopped", isCurrent: false))
        let unlisted = ServerSwitcherRow.make(
            id("/tmp/acme/herdr.sock"), entries: Self.entries, currentSocket: Self.defaultSocket, home: Self.home
        )
        XCTAssertEqual(unlisted, ServerSwitcherRow(label: "acme", status: nil, isCurrent: false))
    }

    func testOptionBacktickKeys() {
        func decide(
            _ trigger: SwitcherTrigger, _ keyCode: UInt16, control: Bool = false, shift: Bool = false, command: Bool = false,
            option: Bool = true, active: Bool = false
        ) -> SwitcherKey.Decision {
            SwitcherKey.decide(
                trigger: trigger, keyCode: keyCode, control: control, shift: shift, command: command, option: option, active: active
            )
        }
        let grave: UInt16 = 50
        let tab: UInt16 = 48
        XCTAssertEqual(decide(.optionBacktick, grave), .next)
        XCTAssertEqual(decide(.optionBacktick, grave, shift: true), .previous)
        XCTAssertEqual(decide(.optionBacktick, grave, option: false), .pass)
        XCTAssertEqual(decide(.optionBacktick, grave, control: true), .pass, "⌃⌥` is not the server switcher's")
        XCTAssertEqual(decide(.optionBacktick, grave, command: true), .pass, "⌘⌥` is not the server switcher's")
        XCTAssertEqual(decide(.optionBacktick, tab), .pass, "⌥Tab stays the tab switcher's")
        XCTAssertEqual(decide(.optionTab, grave), .pass, "⌥` is not the tab switcher's")
        XCTAssertEqual(decide(.controlBacktick, grave), .pass, "⌥` is not the profile switcher's")
        XCTAssertEqual(decide(.optionBacktick, grave, control: true, option: false), .pass, "⌃` is not the server switcher's")
        XCTAssertEqual(decide(.optionBacktick, tab, control: true, option: false), .pass, "nor is ⌃Tab")
        XCTAssertTrue(SwitcherKey.isHeld(.optionBacktick, control: false, option: true))
        XCTAssertFalse(SwitcherKey.isHeld(.optionBacktick, control: true, option: false))
        XCTAssertEqual(SwitcherTrigger.optionBacktick.label, "\u{2325}`")
    }

    @MainActor
    func testBacktickPressThatOpensNothingStaysOutOfThePane() {
        let switcher = ServerSwitcher(userDefaults: UserDefaults(suiteName: "flock.tests.\(UUID().uuidString)")!)
        XCTAssertTrue(SwitcherTrigger.optionBacktick.keepsUnopenedPress)
        XCTAssertTrue(SwitcherTrigger.controlBacktick.keepsUnopenedPress)
        XCTAssertFalse(SwitcherTrigger.optionTab.keepsUnopenedPress, "an unopened Tab still reaches the pane")
        XCTAssertTrue(switcher.apply(.next, keepsUnopened: true, begin: { _ in false }, open: {}))
        XCTAssertFalse(switcher.apply(.next, keepsUnopened: false, begin: { _ in false }, open: {}))
        XCTAssertFalse(switcher.apply(.pass, keepsUnopened: true, begin: { _ in false }, open: {}))
    }
}
