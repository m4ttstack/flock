import XCTest
@testable import FlockCore

final class ProfilePickerModelTests: XCTestCase {
    private let mini = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
    private let studio = HerdrMachine(id: "fedcba9876543210fedcba9876543210", label: "acme-studio", target: "acme-studio", session: "default")

    private var profiles: [FlockProfile] {
        [
            FlockProfile(id: FlockProfile.defaultID, name: "Default", socketPath: nil, knownSockets: []),
            FlockProfile(id: "p1", name: "Demo", socketPath: nil, knownSockets: []),
            FlockProfile(id: "machine.\(mini.id)", name: "acme-mini", socketPath: nil, knownSockets: [], machine: mini),
            FlockProfile(id: "machine.\(studio.id)", name: "acme-studio", socketPath: nil, knownSockets: [], machine: studio),
        ]
    }

    func testLocalProfilesComeFirstThenMachines() {
        let model = ProfilePickerModel(profiles: profiles, currentID: FlockProfile.defaultID, currentDot: nil)
        XCTAssertEqual(model.local.map(\.title), ["Default", "Demo"])
        XCTAssertEqual(model.machines.map(\.title), ["acme-mini", "acme-studio"])
        XCTAssertEqual(model.rows.map(\.title), ["Default", "Demo", "acme-mini", "acme-studio"])
        XCTAssertEqual(model.local.map(\.isMachine), [false, false])
        XCTAssertEqual(model.machines.map(\.isMachine), [true, true])
    }

    func testOnlyTheCurrentRowIsMarkedCurrent() {
        let model = ProfilePickerModel(profiles: profiles, currentID: "p1", currentDot: nil)
        XCTAssertEqual(model.rows.filter(\.isCurrent).map(\.id), ["p1"])
        XCTAssertEqual(model.current?.title, "Demo")
        XCTAssertEqual(model.currentIndex, 1)
    }

    func testOnlyTheCurrentMachineCarriesTheDot() {
        let model = ProfilePickerModel(profiles: profiles, currentID: "machine.\(mini.id)", currentDot: .attention)
        XCTAssertEqual(model.rows.map(\.dot), [nil, nil, .attention, nil])
        XCTAssertEqual(model.current?.dot, .attention)
    }

    func testALocalProfileNeverCarriesADot() {
        let model = ProfilePickerModel(profiles: profiles, currentID: FlockProfile.defaultID, currentDot: .live)
        XCTAssertEqual(model.rows.map(\.dot), [nil, nil, nil, nil])
    }

    func testNoMachinesLeavesTheSectionEmpty() {
        let model = ProfilePickerModel(profiles: Array(profiles.prefix(2)), currentID: FlockProfile.defaultID, currentDot: nil)
        XCTAssertEqual(model.machines, [])
        XCTAssertEqual(model.rows.count, 2)
    }

    func testTheDotFollowsTheMachineNotice() {
        XCTAssertEqual(ProfileConnectionDot.forMachine(hasNotice: false), .live)
        XCTAssertEqual(ProfileConnectionDot.forMachine(hasNotice: true), .attention)
    }

    func testStepsStopAtTheEnds() {
        XCTAssertEqual(ProfilePickerModel.step(from: 0, by: -1, count: 4), 0)
        XCTAssertEqual(ProfilePickerModel.step(from: 1, by: 1, count: 4), 2)
        XCTAssertEqual(ProfilePickerModel.step(from: 3, by: 1, count: 4), 3)
        XCTAssertEqual(ProfilePickerModel.step(from: 0, by: 1, count: 0), 0)
    }
}
