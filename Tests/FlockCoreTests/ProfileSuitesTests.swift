import XCTest
@testable import FlockCore

final class ProfileSuitesTests: XCTestCase {
    private let homeSocket = "/Users/someone/.config/herdr/herdr.sock"
    private let acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"

    func testDefaultOnTheDefaultSocketUsesStandard() {
        XCTAssertNil(ProfileSuites.preferencesSuiteName(bundleID: "b", profile: defaultProfile))
        XCTAssertNil(ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: homeSocket, defaultSocketPath: homeSocket))
    }

    func testDefaultOnAnotherServerGetsItsOwnServerSuite() {
        XCTAssertEqual(
            ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: acme, defaultSocketPath: homeSocket),
            "b.profile.default.server.\(ProfileSuites.socketKey(acme))"
        )
    }

    func testAnotherProfileGetsBothSuites() {
        XCTAssertEqual(ProfileSuites.preferencesSuiteName(bundleID: "b", profile: FlockProfile(id: "p1", name: "P1", socketPath: nil, knownSockets: [])), "b.profile.p1")
        XCTAssertEqual(
            ProfileSuites.serverSuiteName(bundleID: "b", profileID: "p1", socketPath: homeSocket, defaultSocketPath: homeSocket),
            "b.profile.p1.server.\(ProfileSuites.socketKey(homeSocket))"
        )
    }

    private let defaultProfile = FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: [])
    private let machineProfile = FlockProfile(
        id: "machine.0123456789abcdef0123456789abcdef", name: "acme-mini", socketPath: nil, knownSockets: [],
        machine: HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
    )

    func testMachineProfileSharesDefaultPreferences() {
        XCTAssertNil(ProfileSuites.preferencesSuiteName(bundleID: "b", profile: machineProfile))
    }

    func testMachineAttachKeyIsMachineID() {
        XCTAssertEqual(
            ProfileSuites.attachKey(for: machineProfile, socketPath: "/tmp/flock-501/dev-0123456789ab/herdr.sock"),
            "herdr-machine:0123456789abcdef0123456789abcdef"
        )
    }

    func testOtherProfilesAttachByNormalizedSocket() {
        XCTAssertEqual(ProfileSuites.attachKey(for: defaultProfile, socketPath: acme), acme)
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
