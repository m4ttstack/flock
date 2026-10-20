import XCTest
@testable import FlockCore

final class ProfileSuitesTests: XCTestCase {
    private let homeSocket = "/Users/someone/.config/herdr/herdr.sock"
    private let acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"

    func testDefaultOnTheDefaultSocketUsesStandard() {
        XCTAssertNil(ProfileSuites.preferencesSuiteName(bundleID: "b", profileID: "default"))
        XCTAssertNil(ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: homeSocket, defaultSocketPath: homeSocket))
    }

    func testDefaultOnAnotherServerGetsItsOwnServerSuite() {
        XCTAssertEqual(
            ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: acme, defaultSocketPath: homeSocket),
            "b.profile.default.server.\(ProfileSuites.socketKey(acme))"
        )
    }

    func testAnotherProfileGetsBothSuites() {
        XCTAssertEqual(ProfileSuites.preferencesSuiteName(bundleID: "b", profileID: "p1"), "b.profile.p1")
        XCTAssertEqual(
            ProfileSuites.serverSuiteName(bundleID: "b", profileID: "p1", socketPath: homeSocket, defaultSocketPath: homeSocket),
            "b.profile.p1.server.\(ProfileSuites.socketKey(homeSocket))"
        )
    }

    func testOverrideSuite() {
        XCTAssertEqual(ProfileSuites.overrideSuiteName(bundleID: "b"), "b.override")
    }

    func testSocketKeyIgnoresSpelling() {
        let spelled = HerdrServerAddress.normalize("~/.config/herdr/sessions/acme/./herdr.sock", home: "/Users/someone")
        XCTAssertEqual(ProfileSuites.socketKey(acme).count, 12)
        XCTAssertEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(spelled))
        XCTAssertNotEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(homeSocket))
    }
}
