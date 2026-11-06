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

    func testNeverUsedProfilesFollowThePickerLocalThenMachines() {
        let switcher = makeSwitcher()
        let shuffled = [Self.profiles[2], Self.profiles[1], Self.profiles[0]]
        XCTAssertEqual(
            ProfileSwitcher.candidates(shuffled, isLocked: false), ids("acme-work", FlockProfile.defaultID, Self.miniID)
        )
        XCTAssertTrue(switcher.begin(
            items: ProfileSwitcher.candidates(shuffled, isLocked: false), current: ProfileID(rawValue: Self.miniID)
        ))
        XCTAssertEqual(switcher.order, ids(Self.miniID, "acme-work", FlockProfile.defaultID))
    }

    func testATriggerThatStartsNothingReachesThePane() {
        let switcher = makeSwitcher()
        let one = ProfileSwitcher.candidates(Array(Self.profiles.prefix(1)), isLocked: false)
        let current = ProfileID(rawValue: FlockProfile.defaultID)
        let begin = { (reverse: Bool) in switcher.begin(items: one, current: current, reverse: reverse) }
        XCTAssertFalse(switcher.apply(.next, begin: begin, open: {}), "one profile: ⌃` goes to the terminal")
        XCTAssertFalse(switcher.apply(.previous, begin: begin, open: {}))
        XCTAssertFalse(switcher.apply(.pass, begin: begin, open: {}))
        XCTAssertFalse(switcher.isActive)

        let all = ProfileSwitcher.candidates(Self.profiles, isLocked: false)
        XCTAssertTrue(switcher.apply(.next, begin: { switcher.begin(items: all, current: current, reverse: $0) }, open: {}))
        XCTAssertTrue(switcher.isActive)
        XCTAssertTrue(switcher.apply(.next, begin: { _ in XCTFail("an open switcher steps"); return false }, open: {}))
        XCTAssertEqual(switcher.selection, 2)
        XCTAssertTrue(switcher.apply(.swallow, begin: { _ in false }, open: {}))
        var opened = false
        XCTAssertTrue(switcher.apply(.commit, begin: { _ in false }, open: { opened = true }))
        XCTAssertTrue(opened)
        XCTAssertTrue(switcher.apply(.cancel, begin: { _ in false }, open: {}))
        XCTAssertFalse(switcher.isActive)
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

    func testTheServerSwitcherAndTheOthersBlockEachOther() {
        let up = SwitcherBlockers(active: [.servers])
        XCTAssertFalse(up.blocks(.servers))
        for kind in [SwitcherKind.workspaces, .tabs, .profiles] {
            XCTAssertTrue(up.blocks(kind), "servers up blocks \(kind)")
            XCTAssertTrue(SwitcherBlockers(active: [kind]).blocks(.servers), "\(kind) up blocks servers")
        }
        XCTAssertFalse(SwitcherBlockers().blocks(.servers))
    }

    func testModalLayersBlockEverySwitcher() {
        let layers = [
            SwitcherBlockers(paletteOpen: true), SwitcherBlockers(renaming: true), SwitcherBlockers(rtModal: true),
            SwitcherBlockers(profilePickerOpen: true),
        ]
        for blockers in layers {
            for kind in [SwitcherKind.workspaces, .tabs, .profiles, .servers] {
                XCTAssertTrue(blockers.blocks(kind), "\(blockers) blocks \(kind)")
            }
        }
    }
}
