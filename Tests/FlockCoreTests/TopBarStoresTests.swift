import XCTest
@testable import FlockCore

@MainActor
final class TopBarStoresTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "flock-topbar-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testSizeDefaultsToMediumAndPersistsPerPin() {
        let defaults = defaults()
        let a = PinID(rawValue: "a"), b = PinID(rawValue: "b")
        let store = TopBarOverlaySizeStore(userDefaults: defaults)
        XCTAssertEqual(store.size(for: a), .medium)
        store.select(.large, for: a)
        store.select(.small, for: b)
        let reloaded = TopBarOverlaySizeStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.size(for: a), .large)
        XCTAssertEqual(reloaded.size(for: b), .small)
        reloaded.forget(a)
        XCTAssertEqual(TopBarOverlaySizeStore(userDefaults: defaults).size(for: a), .medium)
    }

    func testAnUnknownStoredSizeReadsAsMedium() {
        let defaults = defaults()
        defaults.set(Data(#"{"a":"huge"}"#.utf8), forKey: TopBarOverlaySizeStore.defaultsKey)
        XCTAssertEqual(TopBarOverlaySizeStore(userDefaults: defaults).size(for: PinID(rawValue: "a")), .medium)
    }

    func testLabelDefaultsToIconOnlyAndPersists() {
        let defaults = defaults()
        XCTAssertEqual(TopBarLabelStore(userDefaults: defaults).label, .iconOnly)
        TopBarLabelStore(userDefaults: defaults).select(.iconAndName)
        XCTAssertEqual(TopBarLabelStore(userDefaults: defaults).label, .iconAndName)
    }

    func testNamesShowOnlyWhenTheNamedStripFits() {
        XCTAssertTrue(TitleBarFit.showsNames(barWidth: 1000, leadingEdge: 300, noticesWidth: 0, namedStripWidth: 400, gap: 16))
        XCTAssertFalse(TitleBarFit.showsNames(barWidth: 700, leadingEdge: 300, noticesWidth: 0, namedStripWidth: 400, gap: 16))
        XCTAssertFalse(TitleBarFit.showsNames(barWidth: 1000, leadingEdge: 300, noticesWidth: 300, namedStripWidth: 400, gap: 16))
    }
}
