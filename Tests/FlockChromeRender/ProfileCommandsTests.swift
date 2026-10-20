import XCTest
@testable import FlockCore

final class ProfileCommandsTests: XCTestCase {
    func testRowsListEveryProfileAndCheckTheCurrent() {
        let profiles = [
            FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: []),
            FlockProfile(id: "p1", name: "Demo", socketPath: nil, knownSockets: []),
        ]
        XCTAssertEqual(ProfileCommands.rows(profiles: profiles, currentID: "p1"), [
            ProfileMenuRow(id: "default", title: "Default", isCurrent: false),
            ProfileMenuRow(id: "p1", title: "Demo", isCurrent: true),
        ])
    }

    func testOnlyTheProfileCurrentAtClickTimeGoesThroughChangeServer() {
        XCTAssertEqual(ProfilesSettingsSection.serverRoute(for: "p1", currentID: "p1"), .changeServer)
        XCTAssertEqual(ProfilesSettingsSection.serverRoute(for: "p1", currentID: "default"), .setSocket)
    }

    func testServerNameFollowsTheProfileName() {
        XCTAssertEqual(ProfilesSettingsSection.serverName(for: "Demo Video"), "demo-video")
        XCTAssertEqual(ProfilesSettingsSection.serverName(for: " .Mé & co_1.2"), "m----co_1.2")
    }
}
