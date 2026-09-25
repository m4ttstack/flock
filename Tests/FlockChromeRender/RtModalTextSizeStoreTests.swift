import XCTest
@testable import FlockCore

@MainActor
final class RtModalTextSizeStoreTests: XCTestCase {
    private static let suite = "flock.render.rt-modal-text-size"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    func testEachCommandStartsAtRegular() throws {
        let store = RtModalTextSizeStore(userDefaults: try makeDefaults())
        for kind in RtKind.allCases {
            XCTAssertEqual(store.size(for: kind), .regular, "\(kind)")
        }
    }

    func testEachCommandKeepsItsOwnSizeAcrossLaunches() throws {
        let defaults = try makeDefaults()
        let store = RtModalTextSizeStore(userDefaults: defaults)
        store.select(.compact, for: .glitter)
        store.select(.large, for: .runner)

        let relaunched = RtModalTextSizeStore(userDefaults: defaults)
        XCTAssertEqual(relaunched.size(for: .glitter), .compact)
        XCTAssertEqual(relaunched.size(for: .runner), .large)
        XCTAssertEqual(relaunched.size(for: .nav), .regular, "choosing glitter's size moved nav's")
        XCTAssertEqual(relaunched.size(for: .run), .regular, "choosing runner's size moved run's")
    }
}
