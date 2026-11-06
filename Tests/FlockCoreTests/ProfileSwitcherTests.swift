import XCTest
@testable import FlockCore

@MainActor
final class ProfileSwitcherTests: XCTestCase {
    private nonisolated static let suite = "ProfileSwitcherTests"
    private static let mini = HerdrMachine(
        id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default"
    )
    private static let profiles = [
        FlockProfile(id: FlockProfile.defaultID, name: "Default", socketPath: nil, knownSockets: []),
        FlockProfile(id: "acme-work", name: "acme work", socketPath: "/tmp/acme.sock", knownSockets: []),
        FlockProfile(id: "machine.\(mini.id)", name: "acme-mini", socketPath: nil, knownSockets: [], machine: mini),
    ]
    private static let miniID = "machine.\(mini.id)"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func makeSwitcher() -> ProfileSwitcher {
        ProfileSwitcher(userDefaults: UserDefaults(suiteName: Self.suite)!)
    }

    private func ids(_ raw: String...) -> [ProfileID] { raw.map { ProfileID(rawValue: $0) } }

    func testRecentsLiveUnderTheirOwnKeyAndSurviveARelaunch() {
        let switcher = makeSwitcher()
        switcher.note(currentProfile: FlockProfile.defaultID)
        switcher.note(currentProfile: Self.miniID)
        let defaults = UserDefaults(suiteName: Self.suite)!
        XCTAssertEqual(defaults.stringArray(forKey: "flock.profileRecents"), [Self.miniID, FlockProfile.defaultID])
        XCTAssertEqual(makeSwitcher().recents, ids(Self.miniID, FlockProfile.defaultID))
    }

    func testATapFlipsBetweenTheLastTwoProfiles() {
        let switcher = makeSwitcher()
        let candidates = ProfileSwitcher.candidates(Self.profiles, isLocked: false)
        switcher.note(currentProfile: "acme-work")
        switcher.note(currentProfile: FlockProfile.defaultID)
        switcher.note(currentProfile: Self.miniID)

        XCTAssertTrue(switcher.begin(items: candidates, current: ProfileID(rawValue: Self.miniID)))
        XCTAssertEqual(switcher.order, ids(Self.miniID, FlockProfile.defaultID, "acme-work"), "current, then most recent first")
        XCTAssertEqual(switcher.finish(), ProfileID(rawValue: FlockProfile.defaultID))

        switcher.note(currentProfile: FlockProfile.defaultID)
        XCTAssertTrue(switcher.begin(items: candidates, current: ProfileID(rawValue: FlockProfile.defaultID)))
        XCTAssertEqual(switcher.finish(), ProfileID(rawValue: Self.miniID), "a second tap goes back")
    }

    func testAProfileNeverUsedFollowsTheRecentsInStoreOrder() {
        let switcher = makeSwitcher()
        switcher.note(currentProfile: FlockProfile.defaultID)
        XCTAssertTrue(switcher.begin(
            items: ProfileSwitcher.candidates(Self.profiles, isLocked: false), current: ProfileID(rawValue: FlockProfile.defaultID)
        ))
        XCTAssertEqual(switcher.order, ids(FlockProfile.defaultID, "acme-work", Self.miniID))
        switcher.step(1)
        XCTAssertEqual(switcher.selected, ProfileID(rawValue: Self.miniID))
        switcher.step(1)
        XCTAssertEqual(switcher.finish(), nil, "stepping back round to the current profile goes nowhere")
    }

    func testARemovedMachineIsLeftOut() {
        let switcher = makeSwitcher()
        switcher.note(currentProfile: "machine.gone")
        switcher.note(currentProfile: FlockProfile.defaultID)
        XCTAssertTrue(switcher.begin(
            items: ProfileSwitcher.candidates(Array(Self.profiles.prefix(2)), isLocked: false),
            current: ProfileID(rawValue: FlockProfile.defaultID)
        ))
        XCTAssertEqual(switcher.order, ids(FlockProfile.defaultID, "acme-work"))
    }

    func testOneProfileOrALockedWindowHasNothingToSwitchTo() {
        let switcher = makeSwitcher()
        let current = ProfileID(rawValue: FlockProfile.defaultID)
        XCTAssertFalse(switcher.begin(items: ProfileSwitcher.candidates(Array(Self.profiles.prefix(1)), isLocked: false), current: current))
        XCTAssertFalse(switcher.begin(items: ProfileSwitcher.candidates(Self.profiles, isLocked: true), current: current))
        XCTAssertFalse(switcher.isActive)
    }

    func testControlBacktickKeys() {
        func decide(_ keyCode: UInt16, control: Bool = true, shift: Bool = false, command: Bool = false, option: Bool = false, active: Bool = false)
            -> SwitcherKey.Decision {
            SwitcherKey.decide(
                trigger: .controlBacktick, keyCode: keyCode, control: control, shift: shift, command: command, option: option,
                active: active
            )
        }
        let grave: UInt16 = 50
        let tab: UInt16 = 48
        XCTAssertEqual(decide(grave), .next)
        XCTAssertEqual(decide(grave, shift: true), .previous)
        XCTAssertEqual(decide(grave, active: true), .next)
        XCTAssertEqual(decide(grave, control: false), .pass)
        XCTAssertEqual(decide(grave, option: true), .pass, "⌃⌥` is not the profile switcher's")
        XCTAssertEqual(decide(grave, command: true), .pass, "⌘⌃` is not the profile switcher's")
        XCTAssertEqual(decide(tab), .pass, "⌃Tab stays the workspace switcher's")
        XCTAssertEqual(decide(tab, active: true), .swallow)
        XCTAssertEqual(decide(53, active: true), .cancel)
        XCTAssertEqual(decide(36, active: true), .commit)
        XCTAssertEqual(decide(126, active: true), .previous)
        XCTAssertEqual(
            SwitcherKey.decide(trigger: .controlTab, keyCode: grave, control: true, shift: false, command: false, option: false, active: false),
            .pass, "⌃` is not the workspace switcher's"
        )
        XCTAssertTrue(SwitcherKey.isHeld(.controlBacktick, control: true, option: false))
        XCTAssertFalse(SwitcherKey.isHeld(.controlBacktick, control: false, option: true))
    }

    func testTriggerLabels() {
        XCTAssertEqual(SwitcherTrigger.controlBacktick.label, "\u{2303}`")
        XCTAssertEqual(SwitcherTrigger.controlTab.label, "\u{2303}\u{21E5}")
        XCTAssertEqual(SwitcherTrigger.optionTab.label, "\u{2325}\u{21E5}")
    }

    func testAnOpenSwitcherBlocksTheOthersButNotItself() {
        let up = SwitcherBlockers(active: [.profiles])
        XCTAssertFalse(up.blocks(.profiles))
        XCTAssertTrue(up.blocks(.workspaces))
        XCTAssertTrue(up.blocks(.tabs))
        XCTAssertTrue(SwitcherBlockers(active: [.workspaces]).blocks(.profiles))
        XCTAssertTrue(SwitcherBlockers(active: [.tabs]).blocks(.profiles))
        XCTAssertFalse(SwitcherBlockers().blocks(.profiles))
    }

    func testModalLayersBlockEverySwitcher() {
        let layers = [
            SwitcherBlockers(paletteOpen: true), SwitcherBlockers(renaming: true), SwitcherBlockers(rtModal: true),
            SwitcherBlockers(profilePickerOpen: true),
        ]
        for blockers in layers {
            for kind in [SwitcherKind.workspaces, .tabs, .profiles] {
                XCTAssertTrue(blockers.blocks(kind), "\(blockers) blocks \(kind)")
            }
        }
    }
}
