import XCTest
@testable import FlockCore

@MainActor
final class PaletteRankingTests: XCTestCase {
    private nonisolated static let suite = "PaletteRankingTests"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private let commands = [
        PaletteCommand(id: "view.rearrange", namespace: .view, name: "Rearrange Mode", shortcut: "⌘R"),
        PaletteCommand(id: "pane.splitright", namespace: .pane, name: "Split Right", shortcut: "⌘D"),
        PaletteCommand(id: "rt.glitter", namespace: .rt, name: "glitter", hint: "Review and commit"),
        PaletteCommand(id: "rt.nav", namespace: .rt, name: "nav", hint: "Browse files"),
        PaletteCommand(id: "chat.peek", namespace: .chat, name: "Chat Peek", shortcut: "⇧⌘P"),
    ]

    func testAnEmptySearchGroupsEverythingByNamespaceOrder() {
        let rows = PaletteRanking.rows(commands: commands, query: "", recents: [])
        XCTAssertEqual(rows.map(\.command.id), ["rt.glitter", "rt.nav", "pane.splitright", "chat.peek", "view.rearrange"])
        XCTAssertEqual(Set(rows.map(\.section)), [.all])
    }

    /// Recents that cannot run now are skipped, and the next one fills the slot.
    func testRecentsComeFirstCappedAtThreeAndNeverRepeat() {
        let recents = ["chat.gone", "view.rearrange", "rt.nav", "chat.peek", "pane.splitright"]
        let rows = PaletteRanking.rows(commands: commands, query: "", recents: recents)
        XCTAssertEqual(rows.prefix(3).map(\.command.id), ["view.rearrange", "rt.nav", "chat.peek"])
        XCTAssertEqual(rows.prefix(3).map(\.section), [.recent, .recent, .recent])
        XCTAssertEqual(rows.dropFirst(3).map(\.command.id), ["rt.glitter", "pane.splitright"])
    }

    func testATypedSearchIsOneRankedListWithHighlights() {
        let rows = PaletteRanking.rows(commands: commands, query: "gl", recents: [])
        XCTAssertEqual(rows.first?.command.id, "rt.glitter")
        XCTAssertEqual(rows.first?.nameIndices, [0, 1])
        XCTAssertNil(rows.first?.section)
    }

    func testARecentCommandRanksAboveAnEqualMatch() {
        let pair = [
            PaletteCommand(id: "pane.focusleft", namespace: .pane, name: "Focus Pane Left"),
            PaletteCommand(id: "pane.focusright", namespace: .pane, name: "Focus Pane Right"),
        ]
        let rows = PaletteRanking.rows(commands: pair, query: "focus", recents: ["pane.focusright"])
        XCTAssertEqual(rows.map(\.command.id), ["pane.focusright", "pane.focusleft"])
    }

    func testASearchThatMatchesNothingHasNoRows() {
        XCTAssertTrue(PaletteRanking.rows(commands: commands, query: "zzz", recents: []).isEmpty)
    }

    func testTheRecentsStorePersistsDeduplicatesAndCaps() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let store = PaletteRecentsStore(userDefaults: defaults)
        for index in 0..<25 { store.record("cmd.\(index)") }
        store.record("cmd.20")
        let reread = PaletteRecentsStore(userDefaults: defaults)
        XCTAssertEqual(reread.ids.count, PaletteRecentsStore.storedLimit)
        XCTAssertEqual(reread.ids.first, "cmd.20")
        XCTAssertEqual(reread.ids.filter { $0 == "cmd.20" }.count, 1)
    }
}
