import XCTest
@testable import FlockCore

final class FlockClientsTests: XCTestCase {
    private let home = "/Users/someone/.config/herdr/herdr.sock"
    private let work = "/Users/someone/.config/herdr/sessions/work/herdr.sock"

    private func record(_ pid: Int32, _ socket: String, name: String = "Flock") -> FlockClientRecord {
        FlockClientRecord(pid: pid, bundleID: "dev.mattstack.Flock", appName: name, socketPath: socket)
    }

    private func running(_ pid: Int32, name: String = "Flock") -> RunningFlock {
        RunningFlock(pid: pid, bundleID: "dev.mattstack.Flock", appName: name)
    }

    private func others(
        socket: String, records: [FlockClientRecord], running: [RunningFlock]
    ) -> [Int32] {
        FlockClientConflict.others(
            attachedTo: socket, selfPID: 100, records: records, running: running, defaultSocketPath: home
        ).map(\.pid)
    }

    func testAnotherFlockOnTheSameSessionConflicts() {
        XCTAssertEqual(others(socket: home, records: [record(200, home)], running: [running(100), running(200)]), [200])
    }

    func testAFlockOnAnotherSessionDoesNot() {
        XCTAssertEqual(others(socket: home, records: [record(200, work)], running: [running(200)]), [])
    }

    func testThisProcessIsNeverItsOwnConflict() {
        XCTAssertEqual(others(socket: home, records: [record(100, home)], running: [running(100)]), [])
    }

    /// A crash leaves its record behind; a process that is not running holds
    /// no session.
    func testARecordWhoseProcessIsGoneIsIgnored() {
        XCTAssertEqual(others(socket: home, records: [record(300, home)], running: []), [])
    }

    /// Flock 0.1.0 writes no record, and could only be on the default session.
    func testARunningFlockWithNoRecordIsTakenToBeOnTheDefaultSession() {
        XCTAssertEqual(others(socket: home, records: [], running: [running(400)]), [400])
        XCTAssertEqual(others(socket: work, records: [], running: [running(400)]), [])
    }

    func testTwoSpellingsOfOneSocketAreOneSession() {
        let dotted = "/Users/someone/.config/herdr/./herdr.sock"
        XCTAssertEqual(others(socket: dotted, records: [record(200, home)], running: [running(200)]), [200])
    }

    func testTheRegistryRoundTripsAndForgets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flock-clients-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = FlockClientRegistry(directory: directory)

        try registry.register(record(200, home, name: "Flock Dev"))
        try registry.register(record(201, work))
        XCTAssertEqual(Set(registry.records().map(\.pid)), [200, 201])
        XCTAssertEqual(registry.records().first { $0.pid == 200 }?.appName, "Flock Dev")

        registry.unregister(pid: 200)
        XCTAssertEqual(registry.records().map(\.pid), [201])
    }
}
