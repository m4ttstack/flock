import XCTest
@testable import PaddockCore

final class HerdrModelTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle(for: HerdrModelTests.self).url(forResource: name, withExtension: nil)!)
    }
    func fixtureLines(_ name: String) throws -> [Data] {
        try (fixture(name).split(separator: 0x0A) as [Data])
    }

    func testSnapshotFixtureDecodes() throws {
        let data = try fixture("snapshot.json")
        let snap = try HerdrDecoder.snapshot(fromResponseLine: data)
        XCTAssertGreaterThan(snap.workspaces.count, 0)
        XCTAssertEqual(snap.layouts.first?.panes.isEmpty, false)
        XCTAssertGreaterThanOrEqual(snap.protocolVersion, 19)
    }

    func testEventFixtureLinesDecode() throws {
        for line in try fixtureLines("events.ndjson") {
            XCTAssertNoThrow(try HerdrDecoder.event(fromLine: line))
        }
    }

    func testUnknownEventTypeIsTolerated() throws {
        let ev = try HerdrDecoder.event(fromLine: Data(#"{"data":{"type":"pane.hologram","x":1}}"#.utf8))
        guard case .unknown(let t) = ev else { return XCTFail() }
        XCTAssertEqual(t, "pane.hologram")
    }
}
