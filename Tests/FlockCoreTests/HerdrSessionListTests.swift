import XCTest
@testable import FlockCore

final class HerdrSessionListTests: XCTestCase {
    private let json = #"{"sessions":[{"default":true,"name":"default","running":true,"session_dir":"/Users/someone/.config/herdr","socket_path":"/Users/someone/.config/herdr/herdr.sock"},{"default":false,"name":"acme","running":false,"session_dir":"/Users/someone/.config/herdr/sessions/acme","socket_path":"/Users/someone/.config/herdr/sessions/acme/herdr.sock"}]}"#

    func testParsesEachSession() {
        XCTAssertEqual(HerdrSessionList.parse(Data(json.utf8)), [
            HerdrSessionEntry(name: "default", isRunning: true, socketPath: "/Users/someone/.config/herdr/herdr.sock", isDefault: true),
            HerdrSessionEntry(name: "acme", isRunning: false, socketPath: "/Users/someone/.config/herdr/sessions/acme/herdr.sock", isDefault: false),
        ])
    }
    func testRejectsOutputThatIsNotTheList() {
        XCTAssertNil(HerdrSessionList.parse(Data("nope".utf8)))
        XCTAssertNil(HerdrSessionList.parse(Data(#"{"sessions":3}"#.utf8)))
    }
    func testStatusLabelNamesRunningAndStopped() {
        XCTAssertEqual(HerdrSessionEntry(name: "a", isRunning: true, socketPath: "/s", isDefault: false).statusLabel, "running")
        XCTAssertEqual(HerdrSessionEntry(name: "a", isRunning: false, socketPath: "/s", isDefault: false).statusLabel, "stopped")
    }
}
