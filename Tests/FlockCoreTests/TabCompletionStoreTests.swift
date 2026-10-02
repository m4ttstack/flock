import XCTest
@testable import FlockCore

@MainActor
final class TabCompletionStoreTests: XCTestCase {
    private nonisolated static let suite = "TabCompletionStoreTests"
    private let tab = TabID(rawValue: "w1:t1")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    func testATabStartsIncompleteAndTogglesBothWays() {
        let store = TabCompletionStore()
        XCTAssertFalse(store.isComplete(tab))

        store.toggle(tab)
        XCTAssertTrue(store.isComplete(tab))
        XCTAssertFalse(store.isComplete(TabID(rawValue: "w1:t2")), "one tab's mark is its own")

        store.toggle(tab)
        XCTAssertFalse(store.isComplete(tab))
    }

    func testAMarkPersistsAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        TabCompletionStore(userDefaults: defaults).toggle(tab)

        XCTAssertTrue(TabCompletionStore(userDefaults: defaults).isComplete(tab))
    }

    /// A closed tab's id can come back on a new tab, which must not arrive
    /// already marked.
    func testATabThatIsGoneIsForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let store = TabCompletionStore(userDefaults: defaults)
        let kept = TabID(rawValue: "w1:t2")
        store.toggle(tab)
        store.toggle(kept)

        store.keepOnly([kept])

        XCTAssertFalse(store.isComplete(tab))
        XCTAssertTrue(store.isComplete(kept))
        XCTAssertFalse(TabCompletionStore(userDefaults: defaults).isComplete(tab))
    }
}
