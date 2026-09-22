import AppKit
import FlockCore
import XCTest

extension BoardSources {
    /// A machine without the board app: rt answers nothing and deck is not
    /// there.
    static let unconfigured = BoardSources(readSetting: { nil }, fetchLogo: { nil })

    static func canned(setting: String = BoardFixture.setting, logo: Data?) -> BoardSources {
        BoardSources(readSetting: { (Data(setting.utf8), 0) }, fetchLogo: { logo })
    }
}

enum BoardFixture {
    static let setting = #"{"ok":true,"key":"board.workspaces","value":{"reviews":"🛹 Reviews","responds":"🛹 Responses","doctors":"🛹 Doctors"},"provenance":[],"migrated":true}"#
    static let names = BoardWorkspaceNames(reviews: "🛹 Reviews", responds: "🛹 Responses", doctors: "🛹 Doctors")
    /// A stand-in for the logo deck serves, which is SVG too: a violet tile.
    static let logo = Data(
        ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7.2" fill="#8a5cf6"/><circle cx="16" cy="16" r="6" fill="#1d1830"/></svg>"##.utf8
    )
}

/// Counts calls and answers each from a script, last answer repeating.
private actor Script<Answer: Sendable> {
    private let answers: [Answer]
    private(set) var calls = 0

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func next() -> Answer {
        defer { calls += 1 }
        return answers[min(calls, answers.count - 1)]
    }
}

@MainActor
final class BoardStoreTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.board-store-tests"

    private func defaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testNoRtMeansNoBoardAndNoLogoFetch() async throws {
        let fetches = Script<Data?>([BoardFixture.logo])
        let store = BoardStore(
            sources: BoardSources(readSetting: { nil }, fetchLogo: { await fetches.next() }), userDefaults: try defaults()
        )
        await store.refresh()
        XCTAssertNil(store.names)
        XCTAssertNil(store.logo)
        let fetchCount = await fetches.calls
        XCTAssertEqual(fetchCount, 0, "no Board, nothing to draw a logo on")
    }

    func testTheSettingIsReadAsRtPrintsIt() async throws {
        let store = BoardStore(sources: .canned(logo: nil), userDefaults: try defaults())
        await store.refresh()
        XCTAssertEqual(store.names, BoardFixture.names)
    }

    func testANonZeroExitIsNoBoard() async throws {
        let store = BoardStore(
            sources: BoardSources(readSetting: { (Data(BoardFixture.setting.utf8), 1) }, fetchLogo: { nil }),
            userDefaults: try defaults()
        )
        await store.refresh()
        XCTAssertNil(store.names)
    }

    /// The setting is read again on every activation, so a change made while
    /// flock was in the background lands the next time it comes forward.
    func testEachRefreshReadsTheSettingAgain() async throws {
        let reads = Script<(stdout: Data, exitCode: Int32)?>([
            (Data(BoardFixture.setting.utf8), 0),
            (Data(#"{"ok":false,"error":"unknown key"}"#.utf8), 1),
        ])
        let store = BoardStore(
            sources: BoardSources(readSetting: { await reads.next() }, fetchLogo: { nil }), userDefaults: try defaults()
        )
        await store.refresh()
        XCTAssertEqual(store.names, BoardFixture.names)
        await store.refresh()
        XCTAssertNil(store.names)
        let readCount = await reads.calls
        XCTAssertEqual(readCount, 2)
    }

    func testRefreshesThatOverlapRunRtOnce() async throws {
        let reads = Script<(stdout: Data, exitCode: Int32)?>([(Data(BoardFixture.setting.utf8), 0)])
        let store = BoardStore(
            sources: BoardSources(
                readSetting: {
                    try? await Task.sleep(for: .milliseconds(50))
                    return await reads.next()
                },
                fetchLogo: { nil }
            ),
            userDefaults: try defaults()
        )
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        let readCount = await reads.calls
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(store.names, BoardFixture.names)
    }

    // MARK: - Logo

    func testTheLogoIsFetchedUntilOneFetchSucceedsAndNotAfter() async throws {
        let fetches = Script<Data?>([nil, BoardFixture.logo])
        let store = BoardStore(
            sources: BoardSources(readSetting: { (Data(BoardFixture.setting.utf8), 0) }, fetchLogo: { await fetches.next() }),
            userDefaults: try defaults()
        )
        await store.refresh()
        XCTAssertNil(store.logo, "deck was down")
        await store.refresh()
        XCTAssertNotNil(store.logo, "and came back by the next activation")
        await store.refresh()
        let fetchCount = await fetches.calls
        XCTAssertEqual(fetchCount, 2)
    }

    func testAFetchedLogoSurvivesARelaunchWithDeckDown() async throws {
        let userDefaults = try defaults()
        let first = BoardStore(sources: .canned(logo: BoardFixture.logo), userDefaults: userDefaults)
        await first.refresh()
        XCTAssertNotNil(first.logo)

        let relaunched = BoardStore(sources: .canned(logo: nil), userDefaults: userDefaults)
        XCTAssertNotNil(relaunched.logo, "the cached logo is there before any read")
        await relaunched.refresh()
        XCTAssertNotNil(relaunched.logo, "and a failed fetch does not take it away")
    }

    func testBytesThatAreNotAnImageAreNeitherShownNorCached() async throws {
        let userDefaults = try defaults()
        let store = BoardStore(
            sources: .canned(logo: Data("<!doctype html><title>502 Bad Gateway</title>".utf8)), userDefaults: userDefaults
        )
        await store.refresh()
        XCTAssertNil(store.logo)
        XCTAssertNil(userDefaults.data(forKey: BoardStore.logoDefaultsKey))
    }

    func testTheFixtureLogoDecodes() {
        XCTAssertNotNil(BoardStore.decodedLogo(BoardFixture.logo))
    }
}
