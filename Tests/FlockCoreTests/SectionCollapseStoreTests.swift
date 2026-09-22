import XCTest
@testable import FlockCore

@MainActor
final class SectionCollapseStoreTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.section-collapse-tests"

    private func defaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEverySectionStartsExpanded() throws {
        let store = SectionCollapseStore(userDefaults: try defaults())
        for section in RailSection.allCases {
            XCTAssertFalse(store.isCollapsed(section), "\(section)")
        }
    }

    func testCollapsingIsRememberedAcrossLaunches() throws {
        let userDefaults = try defaults()
        let store = SectionCollapseStore(userDefaults: userDefaults)
        store.toggle(.board)
        XCTAssertTrue(store.isCollapsed(.board))
        XCTAssertTrue(SectionCollapseStore(userDefaults: userDefaults).isCollapsed(.board))

        store.toggle(.board)
        XCTAssertFalse(SectionCollapseStore(userDefaults: userDefaults).isCollapsed(.board))
    }

    func testEachSectionFoldsOnItsOwn() throws {
        let userDefaults = try defaults()
        let store = SectionCollapseStore(userDefaults: userDefaults)
        store.toggle(.herds)
        XCTAssertTrue(store.isCollapsed(.herds))
        XCTAssertFalse(store.isCollapsed(.board))

        let relaunched = SectionCollapseStore(userDefaults: userDefaults)
        XCTAssertTrue(relaunched.isCollapsed(.herds))
        XCTAssertFalse(relaunched.isCollapsed(.board))
    }

    /// A Herds fold saved before Board existed, under the key Herds has
    /// always used, is still a Herds fold.
    func testHerdsReadsTheKeyItHasAlwaysUsed() throws {
        let userDefaults = try defaults()
        userDefaults.set(true, forKey: "flock.herdsCollapsed")
        let store = SectionCollapseStore(userDefaults: userDefaults)
        XCTAssertTrue(store.isCollapsed(.herds))
        XCTAssertFalse(store.isCollapsed(.board))

        store.toggle(.herds)
        XCTAssertEqual(userDefaults.object(forKey: "flock.herdsCollapsed") as? Bool, false)
    }
}
