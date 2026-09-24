import XCTest
@testable import FlockCore

@MainActor
final class RightClickModeStoreTests: XCTestCase {
    private nonisolated static let suite = "RightClickModeStoreTests"
    private let terminal = TerminalID(rawValue: "term_a1")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    func testAPaneStartsOnTheProgramAndTogglesBothWays() {
        let store = RightClickModeStore()
        XCTAssertEqual(store.mode(for: terminal), .program)

        store.toggle(terminal)
        XCTAssertEqual(store.mode(for: terminal), .menu)
        XCTAssertEqual(store.mode(for: TerminalID(rawValue: "term_b2")), .program, "one pane's toggle is its own")

        store.toggle(terminal)
        XCTAssertEqual(store.mode(for: terminal), .program)
    }

    func testAPaneWithNoTerminalIsOnTheProgram() {
        XCTAssertEqual(RightClickModeStore().mode(for: nil), .program)
    }

    func testATogglePersistsAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        RightClickModeStore(userDefaults: defaults).toggle(terminal)

        XCTAssertEqual(RightClickModeStore(userDefaults: defaults).mode(for: terminal), .menu)
    }

    func testAPaneThatIsGoneIsForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let store = RightClickModeStore(userDefaults: defaults)
        let kept = TerminalID(rawValue: "term_b2")
        store.toggle(terminal)
        store.toggle(kept)

        store.keepOnly([kept])

        XCTAssertEqual(store.mode(for: terminal), .program)
        XCTAssertEqual(store.mode(for: kept), .menu)
        XCTAssertEqual(RightClickModeStore(userDefaults: defaults).mode(for: terminal), .program)
    }
}
