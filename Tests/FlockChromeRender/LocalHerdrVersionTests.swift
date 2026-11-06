import XCTest
@testable import Flock

@MainActor
final class LocalHerdrVersionTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testLoadOnceReadsOnceAndPublishesTheResult() async {
        let reads = Counter()
        let store = LocalHerdrVersion(read: { "0.9.\(reads.next())" })
        XCTAssertNil(store.version)
        await store.loadOnce()
        XCTAssertEqual(store.version, "0.9.1")
        await store.loadOnce()
        XCTAssertEqual(store.version, "0.9.1")
        XCTAssertEqual(reads.count, 1)
    }

    func testAnUnreadableVersionStaysNil() async {
        let store = LocalHerdrVersion(read: { nil })
        await store.loadOnce()
        XCTAssertNil(store.version)
    }
}
