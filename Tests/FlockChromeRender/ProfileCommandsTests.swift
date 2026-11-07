import XCTest
@testable import FlockCore

final class ProfileCommandsTests: XCTestCase {
    func testSectionsListEveryProfileAndCheckTheCurrent() {
        let profiles = [
            FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: []),
            FlockProfile(id: "p1", name: "Demo", socketPath: nil, knownSockets: []),
        ]
        XCTAssertEqual(ProfileCommands.sections(profiles: profiles, currentID: "p1"), [[
            ProfileMenuRow(id: "default", title: "Default", isCurrent: false),
            ProfileMenuRow(id: "p1", title: "Demo", isCurrent: true),
        ]])
    }

    func testMachinesFollowTheUserProfilesInTheirOwnSection() {
        let mini = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
        let profiles = [
            FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: []),
            FlockProfile(id: "machine.\(mini.id)", name: "acme-mini", socketPath: nil, knownSockets: [], machine: mini),
            FlockProfile(id: "p1", name: "Demo", socketPath: nil, knownSockets: []),
        ]
        XCTAssertEqual(ProfileCommands.sections(profiles: profiles, currentID: "machine.\(mini.id)"), [
            [
                ProfileMenuRow(id: "default", title: "Default", isCurrent: false),
                ProfileMenuRow(id: "p1", title: "Demo", isCurrent: false),
            ],
            [ProfileMenuRow(id: "machine.\(mini.id)", title: "acme-mini", isCurrent: true)],
        ])
    }

    @MainActor func testTheShortcutIsControlCommandP() {
        XCTAssertEqual(ProfilePickerContext.shortcutLabel, "\u{2303}\u{2318}P")
    }

    func testOnlyTheProfileCurrentAtClickTimeGoesThroughChangeServer() {
        XCTAssertEqual(ProfilesSettingsSection.serverRoute(for: "p1", currentID: "p1"), .changeServer)
        XCTAssertEqual(ProfilesSettingsSection.serverRoute(for: "p1", currentID: "default"), .setSocket)
    }

    func testServerNameFollowsTheProfileName() {
        XCTAssertEqual(ProfilesSettingsSection.serverName(for: "Demo Video"), "demo-video")
        XCTAssertEqual(ProfilesSettingsSection.serverName(for: " .Mé & co_1.2"), "m----co_1.2")
    }

    func testACustomSocketMustBeAFullPath() {
        let home = "/Users/someone"
        XCTAssertEqual(ProfilesSettingsSection.customSocket("", home: home), String??.none)
        XCTAssertEqual(ProfilesSettingsSection.customSocket("herdr.sock", home: home), String??.none)
        XCTAssertEqual(ProfilesSettingsSection.customSocket("~acme/herdr.sock", home: home), String??.none)
        XCTAssertEqual(ProfilesSettingsSection.customSocket("sessions/acme/herdr.sock", home: home), String??.none)
        XCTAssertEqual(ProfilesSettingsSection.customSocket(" /tmp/acme.sock ", home: home), .some("/tmp/acme.sock"))
        XCTAssertEqual(ProfilesSettingsSection.customSocket("~/.config/herdr/herdr.sock", home: home), .some(nil))
    }
}
