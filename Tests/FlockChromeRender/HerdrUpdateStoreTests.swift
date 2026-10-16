import FlockCore
import XCTest

@MainActor
final class HerdrUpdateStoreTests: XCTestCase {
    private final class Box: @unchecked Sendable { var value: String?; var calls = 0 }

    private func makeStore(latest: Box, installed: String? = "0.9.5", now: @escaping () -> Date) -> HerdrUpdateStore {
        HerdrUpdateStore(
            patchStore: HerdrMousePatchStore(resolveBinaryPath: { nil }),
            installedVersion: { installed },
            fetchLatest: { latest.calls += 1; return latest.value },
            now: now
        )
    }

    func testANewerLatestProducesANote() async {
        let box = Box(); box.value = "0.9.6"
        let store = makeStore(latest: box, now: Date.init)
        await store.checkIfDue()
        XCTAssertEqual(
            store.notice,
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        )
    }

    func testChecksAreAtMostHourly() async {
        let box = Box(); box.value = "0.9.6"
        var clock = Date(timeIntervalSince1970: 0)
        let store = makeStore(latest: box, now: { clock })
        await store.checkIfDue()
        clock += 59 * 60
        await store.checkIfDue()
        XCTAssertEqual(box.calls, 1)
        clock += 2 * 60
        await store.checkIfDue()
        XCTAssertEqual(box.calls, 2)
    }

    func testAFailedFetchShowsNothing() async {
        let box = Box()
        let store = makeStore(latest: box, now: Date.init)
        await store.checkIfDue()
        XCTAssertNil(store.notice)
    }
}
