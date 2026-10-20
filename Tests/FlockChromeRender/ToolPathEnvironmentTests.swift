import XCTest

final class ToolPathEnvironmentTests: XCTestCase {
    func testChildToolsAreToldTheSessionsSocket() {
        let socket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
        let environment = ToolPath.childEnvironment(
            base: ["PATH": "/usr/bin", "HOME": "/Users/someone"], path: "/opt/bin:/usr/bin", herdrSocket: socket
        )
        XCTAssertEqual(environment["HERDR_SOCKET_PATH"], socket)
        XCTAssertEqual(environment["RT_BATCH"], "1")
        XCTAssertEqual(environment["PATH"], "/opt/bin:/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/someone")
    }

    func testNoSocketLeavesTheInheritedOne() {
        let environment = ToolPath.childEnvironment(
            base: ["HERDR_SOCKET_PATH": "/tmp/inherited.sock"], path: "/usr/bin", herdrSocket: nil
        )
        XCTAssertEqual(environment["HERDR_SOCKET_PATH"], "/tmp/inherited.sock")
    }
}
