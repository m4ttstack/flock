# Command Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘K opens a searchable palette of every one-step flock command, over the tab area, acting on the focused pane.

**Architecture:** FlockCore holds the pure pieces (the command value, the fuzzy matcher, ranking with recents, the recents store, the open/query/selection state and the key decision). The app builds the available commands for this moment from the lists that already feed the menus (`FocusedPaneCommand`, `PaneDirectionCommand`, `ChatMenuModel`, the rt popover rows, a new `ViewCommand` list) and draws `CommandPaletteView` as an overlay on the tab area, as `RtModalView` is.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-24-flock-command-palette-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host, ticket id or private link anywhere, in code, fixtures, docs or commit messages. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them). Comments state constraints only; no narration, no decision history.
- Work on `main` in `~/Documents/GitHub/flock` (no worktree). Run `xcodegen` after adding files. Run `Scripts/checks.sh` after `git add`.
- Tests are hermetic: no rt, herdr, herdr-chat or deck spawned; UserDefaults only through a test suite name.
- A `@MainActor` XCTest class's statics read in `setUp`/`tearDown` must be `nonisolated`.
- UI is not done until rendered in a dark and a light theme and looked at (`TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=<dir>`).
- Never launch, quit or kill any app named Flock. Hand over with `Scripts/dev-build.sh` (in place) at the end.
- Build and test with a scratch `-derivedDataPath`:
  `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation -derivedDataPath <scratch>` and
  `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath <scratch>`.
- Every commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Exact values from the spec: ⌘K opens the palette, Clear Notifications moves to ⇧⌘K; RECENT shows 3; recents store keeps 20 under `flock.paletteRecents`; box 520 wide, 44 below the tab area's top, r10; search row 44; rows 32, r6; badge 44x18 r4, text 10.5/600; footer 30.

## Review Focus

1. **A search that matches nothing.** The list must say "No matching commands" and Return must do nothing (Task 3 pins `move` on zero rows and `selectedIndex` nil; Task 6 renders the empty state).
2. **Commands changing while the palette is open** (the focused pane closes, a neighbor appears). The selection must stay inside the list, never index past its end (Task 3: `clampSelection(rowCount:)`).
3. **A recent command that cannot run now** (chat on a shell pane). It must not appear in RECENT, and the next recent fills its slot (Task 2).
4. **⌘K while the rename editor is open.** The editor keeps it: the menu item is disabled while `renameEditorIsOnScreen` (Task 4).
5. **A command that opens its own UI** (Rename Pane's editor, Quick Send's popover). The palette closes before the action runs, so the new UI gets focus (Task 6's click test checks the palette is closed after a run).

---

### Task 1: The command value and the fuzzy matcher (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Palette/PaletteCommand.swift`
- Create: `Sources/FlockCore/Palette/PaletteMatcher.swift`
- Test: `Tests/FlockCoreTests/PaletteMatcherTests.swift`

**Interfaces:**
- Produces:
  - `public enum PaletteNamespace: String, CaseIterable, Sendable { case rt, pane, chat, mouse, view, tab, workspace }` (declaration order is the ALL COMMANDS grouping order)
  - `public struct PaletteCommand: Equatable, Sendable, Identifiable { id: String; namespace: PaletteNamespace; name: String; shortcut: String?; hint: String? }` with `public init(id:namespace:name:shortcut: = nil, hint: = nil)`
  - `public enum PaletteMatcher { public struct Match: Equatable, Sendable { public let score: Int; public let nameIndices: [Int] }; public static func match(_ query: String, against command: PaletteCommand) -> Match? }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class PaletteMatcherTests: XCTestCase {
    private let glitter = PaletteCommand(id: "rt.glitter", namespace: .rt, name: "glitter", hint: "Review and commit")
    private let split = PaletteCommand(id: "pane.splitright", namespace: .pane, name: "Split Right", shortcut: "⌘D")
    private let mouse = PaletteCommand(id: "mouse.rightclicks", namespace: .mouse, name: "Give Right-Clicks to Flock")

    func testAnEmptyQueryMatchesEverythingWithNothingHighlighted() {
        XCTAssertEqual(PaletteMatcher.match("", against: glitter), .init(score: 0, nameIndices: []))
    }

    func testTheNameMatchesAndReportsWhichCharacters() {
        XCTAssertEqual(PaletteMatcher.match("glitter", against: glitter)?.nameIndices, Array(0..<7))
    }

    /// The namespace is part of what is matched, so typing it narrows the list.
    func testTheNamespaceIsMatchedButNeverHighlighted() {
        XCTAssertEqual(PaletteMatcher.match("rt gl", against: glitter)?.nameIndices, [0, 1])
        XCTAssertEqual(PaletteMatcher.match("rtgl", against: glitter)?.nameIndices, [0, 1])
    }

    func testTheHintFindsARowWithoutHighlightingTheName() {
        let match = PaletteMatcher.match("commit", against: glitter)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.nameIndices, [])
    }

    func testMatchingIgnoresCase() {
        XCTAssertNotNil(PaletteMatcher.match("SPLIT", against: split))
    }

    func testCharactersOutOfOrderDoNotMatch() {
        XCTAssertNil(PaletteMatcher.match("xyz", against: glitter))
        XCTAssertNil(PaletteMatcher.match("tilg", against: glitter))
    }

    /// Consecutive characters and word starts outrank the same letters scattered.
    func testARunOfLettersOutranksTheSameLettersScattered() throws {
        let run = try XCTUnwrap(PaletteMatcher.match("glit", against: glitter))
        let scattered = try XCTUnwrap(PaletteMatcher.match("glit", against: mouse))
        XCTAssertGreaterThan(run.score, scattered.score)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/PaletteMatcherTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, `PaletteCommand` and `PaletteMatcher` not found.

- [ ] **Step 3: Write the code**

`Sources/FlockCore/Palette/PaletteCommand.swift`:

```swift
import Foundation

/// The palette's namespaces, in the order ALL COMMANDS groups them.
public enum PaletteNamespace: String, CaseIterable, Sendable {
    case rt, pane, chat, mouse, view, tab, workspace
}

/// One row the palette can show. `id` is what recents remember, so it must
/// not change when a title does not.
public struct PaletteCommand: Equatable, Sendable, Identifiable {
    public let id: String
    public let namespace: PaletteNamespace
    public let name: String
    public let shortcut: String?
    /// Searchable, and drawn where a shortcut would be when there is none.
    public let hint: String?

    public init(id: String, namespace: PaletteNamespace, name: String, shortcut: String? = nil, hint: String? = nil) {
        self.id = id
        self.namespace = namespace
        self.name = name
        self.shortcut = shortcut
        self.hint = hint
    }
}
```

`Sources/FlockCore/Palette/PaletteMatcher.swift`:

```swift
import Foundation

/// A fuzzy subsequence match over "namespace name hint", as VS Code's command
/// mode matches "Category: Name". Spaces in the query are ignored, so "rt gl"
/// and "rtgl" read the same.
public enum PaletteMatcher {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Offsets into the command's `name` of the characters that matched.
        public let nameIndices: [Int]

        public init(score: Int, nameIndices: [Int]) {
            self.score = score
            self.nameIndices = nameIndices
        }
    }

    static let consecutiveBonus = 3
    static let wordStartBonus = 5

    public static func match(_ query: String, against command: PaletteCommand) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, nameIndices: []) }
        let prefix = command.namespace.rawValue + " "
        let haystack = Array((prefix + command.name + (command.hint.map { " " + $0 } ?? "")).lowercased())
        let nameRange = prefix.count..<(prefix.count + command.name.count)
        var score = 0
        var indices: [Int] = []
        var previous: Int?
        var cursor = 0
        for character in needle {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            score += 1
            if let previous, found == previous + 1 { score += consecutiveBonus }
            if found == 0 || !haystack[found - 1].isLetter { score += wordStartBonus }
            if nameRange.contains(found) { indices.append(found - nameRange.lowerBound) }
            previous = found
            cursor = found + 1
        }
        return Match(score: score, nameIndices: indices)
    }
}
```

- [ ] **Step 4: Run xcodegen and the tests**

Run: `xcodegen`, then the test command from Step 2.
Expected: all 7 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Palette Tests/FlockCoreTests/PaletteMatcherTests.swift
Scripts/checks.sh
git commit -m "palette: the command value and its fuzzy matcher" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Recents and ranking (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Palette/PaletteRecentsStore.swift`
- Create: `Sources/FlockCore/Palette/PaletteRanking.swift`
- Test: `Tests/FlockCoreTests/PaletteRankingTests.swift`

**Interfaces:**
- Consumes: `PaletteCommand`, `PaletteNamespace`, `PaletteMatcher` (Task 1).
- Produces:
  - `@MainActor @Observable public final class PaletteRecentsStore { public static let defaultsKey = "flock.paletteRecents"; public static let storedLimit = 20; public private(set) var ids: [String]; public init(userDefaults: UserDefaults = .standard); public func record(_ id: String) }`
  - `public enum PaletteRanking { public static let recentLimit = 3; public enum Section: Equatable, Sendable { case recent, all }; public struct Row: Equatable, Sendable, Identifiable { public let command: PaletteCommand; public let section: Section?; public let nameIndices: [Int]; public var id: String }; public static func rows(commands: [PaletteCommand], query: String, recents: [String]) -> [Row] }`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/PaletteRankingTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, `PaletteRanking` and `PaletteRecentsStore` not found.

- [ ] **Step 3: Write the code**

`Sources/FlockCore/Palette/PaletteRecentsStore.swift`:

```swift
import Foundation
import Observation

/// The commands run from the palette, most recent first, kept across
/// launches the way `RtModalSizeStore` keeps its size.
@MainActor
@Observable
public final class PaletteRecentsStore {
    public static let defaultsKey = "flock.paletteRecents"
    public static let storedLimit = 20

    public private(set) var ids: [String]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        ids = userDefaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.storedLimit { ids.removeLast(ids.count - Self.storedLimit) }
        userDefaults.set(ids, forKey: Self.defaultsKey)
    }
}
```

`Sources/FlockCore/Palette/PaletteRanking.swift`:

```swift
import Foundation

/// The rows the palette shows for a query. Empty: RECENT (up to
/// `recentLimit`, only commands available now) then ALL COMMANDS grouped by
/// namespace in `PaletteNamespace` order. Typed: one list ranked by match
/// score, with a boost for recent use.
public enum PaletteRanking {
    public static let recentLimit = 3

    public enum Section: Equatable, Sendable { case recent, all }

    public struct Row: Equatable, Sendable, Identifiable {
        public let command: PaletteCommand
        public let section: Section?
        public let nameIndices: [Int]
        public var id: String { command.id }
    }

    public static func rows(commands: [PaletteCommand], query: String, recents: [String]) -> [Row] {
        if query.allSatisfy(\.isWhitespace) {
            let byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = recents.compactMap { byID[$0] }.prefix(recentLimit)
            let recentIDs = Set(recent.map(\.id))
            let order = PaletteNamespace.allCases
            let rest = commands.enumerated()
                .filter { !recentIDs.contains($0.element.id) }
                .sorted {
                    let lhs = order.firstIndex(of: $0.element.namespace) ?? 0
                    let rhs = order.firstIndex(of: $1.element.namespace) ?? 0
                    return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                }
                .map(\.element)
            return recent.map { Row(command: $0, section: .recent, nameIndices: []) }
                + rest.map { Row(command: $0, section: .all, nameIndices: []) }
        }
        return commands.enumerated()
            .compactMap { offset, command -> (Row, Int, Int)? in
                guard let match = PaletteMatcher.match(query, against: command) else { return nil }
                let boost = recents.firstIndex(of: command.id).map { max(0, 5 - $0) } ?? 0
                return (Row(command: command, section: nil, nameIndices: match.nameIndices), match.score + boost, offset)
            }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .map(\.0)
    }
}
```

- [ ] **Step 4: Run xcodegen and the tests**

Run: `xcodegen`, then the command from Step 2.
Expected: all 6 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Palette Tests/FlockCoreTests/PaletteRankingTests.swift
Scripts/checks.sh
git commit -m "palette: recents and ranking" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Open state, selection and keys (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Palette/CommandPaletteState.swift`
- Test: `Tests/FlockCoreTests/CommandPaletteStateTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable public final class CommandPaletteState { public private(set) var isOpen: Bool; public var query: String; public private(set) var selection: Int; public init(); public func open(); public func close(); public func toggle(); public func move(_ delta: Int, rowCount: Int); public func select(_ index: Int, rowCount: Int); public func clampSelection(rowCount: Int); public func selectedIndex(rowCount: Int) -> Int? }`
  - `public enum PaletteKey { public enum Decision: Equatable, Sendable { case up, down, run, close, pass }; public static func decide(keyCode: UInt16, characters: String?, control: Bool, command: Bool) -> Decision }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class CommandPaletteStateTests: XCTestCase {
    func testOpeningStartsEmptyOnTheFirstRow() {
        let state = CommandPaletteState()
        state.query = "old"
        state.open()
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selection, 0)
        state.toggle()
        XCTAssertFalse(state.isOpen)
    }

    func testMovingStopsAtEitherEndAndDoesNotWrap() {
        let state = CommandPaletteState()
        state.open()
        state.move(-1, rowCount: 4)
        XCTAssertEqual(state.selection, 0)
        state.move(10, rowCount: 4)
        XCTAssertEqual(state.selection, 3)
    }

    func testTypingReturnsTheSelectionToTheTop() {
        let state = CommandPaletteState()
        state.open()
        state.move(2, rowCount: 4)
        state.query = "gl"
        XCTAssertEqual(state.selection, 0)
    }

    /// Rows can shrink under the selection while the palette is open.
    func testTheSelectionStaysInsideAShrinkingList() {
        let state = CommandPaletteState()
        state.open()
        state.move(5, rowCount: 6)
        state.clampSelection(rowCount: 2)
        XCTAssertEqual(state.selection, 1)
        XCTAssertEqual(state.selectedIndex(rowCount: 2), 1)
    }

    func testNoRowsMeansNothingSelected() {
        let state = CommandPaletteState()
        state.open()
        state.move(1, rowCount: 0)
        XCTAssertNil(state.selectedIndex(rowCount: 0))
    }

    func testTheKeysThePaletteTakes() {
        XCTAssertEqual(PaletteKey.decide(keyCode: 126, characters: nil, control: false, command: false), .up)
        XCTAssertEqual(PaletteKey.decide(keyCode: 125, characters: nil, control: false, command: false), .down)
        XCTAssertEqual(PaletteKey.decide(keyCode: 35, characters: "p", control: true, command: false), .up)
        XCTAssertEqual(PaletteKey.decide(keyCode: 45, characters: "n", control: true, command: false), .down)
        XCTAssertEqual(PaletteKey.decide(keyCode: 36, characters: "\r", control: false, command: false), .run)
        XCTAssertEqual(PaletteKey.decide(keyCode: 76, characters: "\u{3}", control: false, command: false), .run)
        XCTAssertEqual(PaletteKey.decide(keyCode: 53, characters: "\u{1b}", control: false, command: false), .close)
        XCTAssertEqual(PaletteKey.decide(keyCode: 0, characters: "a", control: false, command: false), .pass)
        XCTAssertEqual(PaletteKey.decide(keyCode: 35, characters: "p", control: false, command: true), .pass)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/CommandPaletteStateTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, `CommandPaletteState` and `PaletteKey` not found.

- [ ] **Step 3: Write the code**

`Sources/FlockCore/Palette/CommandPaletteState.swift`:

```swift
import Foundation
import Observation

/// Whether the palette is up, what is typed, and which row is selected. The
/// row count is the caller's: the rows depend on the moment, not on this.
@MainActor
@Observable
public final class CommandPaletteState {
    public private(set) var isOpen = false
    public var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    public private(set) var selection = 0

    public init() {}

    public func open() {
        query = ""
        selection = 0
        isOpen = true
    }

    public func close() {
        isOpen = false
    }

    public func toggle() {
        isOpen ? close() : open()
    }

    public func move(_ delta: Int, rowCount: Int) {
        selection = clamped(selection + delta, rowCount: rowCount)
    }

    public func select(_ index: Int, rowCount: Int) {
        selection = clamped(index, rowCount: rowCount)
    }

    public func clampSelection(rowCount: Int) {
        selection = clamped(selection, rowCount: rowCount)
    }

    public func selectedIndex(rowCount: Int) -> Int? {
        rowCount > 0 ? clamped(selection, rowCount: rowCount) : nil
    }

    private func clamped(_ index: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return min(max(index, 0), rowCount - 1)
    }
}

/// The keys the palette takes before its search field or the window sees
/// them. ⌘ combinations always pass, so the menu bar keeps them.
public enum PaletteKey {
    public enum Decision: Equatable, Sendable { case up, down, run, close, pass }

    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53

    public static func decide(keyCode: UInt16, characters: String?, control: Bool, command: Bool) -> Decision {
        guard !command else { return .pass }
        switch keyCode {
        case upArrow: return .up
        case downArrow: return .down
        case returnKey, keypadEnter: return .run
        case escape: return .close
        default: break
        }
        guard control else { return .pass }
        switch characters?.lowercased() {
        case "p": return .up
        case "n": return .down
        default: return .pass
        }
    }
}
```

- [ ] **Step 4: Run xcodegen and the tests**

Run: `xcodegen`, then the command from Step 2.
Expected: all 6 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Palette/CommandPaletteState.swift Tests/FlockCoreTests/CommandPaletteStateTests.swift
Scripts/checks.sh
git commit -m "palette: open state, selection and keys" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Shared view commands, shortcut labels, ⌘K and ⇧⌘K (app)

**Files:**
- Create: `Sources/Flock/Menus/ViewCommand.swift`
- Create: `Sources/Flock/Menus/ShortcutLabel.swift`
- Create: `Sources/Flock/Menus/PaneDirectionCommand.swift` (moved out of `FlockApp.swift`)
- Modify: `Sources/Flock/FlockApp.swift` (File menu New Tab/New Workspace, the View menu's Rearrange, All Workspaces, Open Oldest Notification, Clear Notifications buttons, a new Command Palette… item, the right-click toggle title; `@State` for `CommandPaletteState` and `PaletteRecentsStore` and their `.environment` injection)
- Modify: `Sources/Flock/Chat/ChatCommands.swift` (move `perform` to `ChatMenuItem`)
- Modify: `README.md` (shortcut table: ⌘K Command palette, ⇧⌘K Clear notifications)
- Test: `Tests/FlockChromeRender/PaletteShortcutTests.swift`

**Interfaces:**
- Consumes: `CommandPaletteState`, `PaletteRecentsStore` (Tasks 2 and 3).
- Produces:
  - `enum ViewCommand: String, CaseIterable { case newTab, newWorkspace, rearrangeMode, allWorkspaces, openOldestNotification, clearNotifications, commandPalette; var title: String; var key: KeyEquivalent; var modifiers: EventModifiers; var shortcut: KeyboardShortcut; var accessibilityIdentifier: String }`
  - `enum ShortcutLabel { static func text(key: KeyEquivalent, modifiers: EventModifiers) -> String }`
  - `enum RightClickToggle { static func title(for mode: RightClickMode?) -> String }`
  - `extension ChatMenuItem { @MainActor func perform(chatStore: ChatStore, viewModel: SessionViewModel) }`

- [ ] **Step 1: Write the failing tests**

`Tests/FlockChromeRender/PaletteShortcutTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import FlockCore

final class PaletteShortcutTests: XCTestCase {
    func testLabelsReadInApplesModifierOrder() {
        XCTAssertEqual(ShortcutLabel.text(key: "d", modifiers: .command), "⌘D")
        XCTAssertEqual(ShortcutLabel.text(key: "k", modifiers: [.command, .shift]), "⇧⌘K")
        XCTAssertEqual(ShortcutLabel.text(key: .leftArrow, modifiers: [.command, .option]), "⌥⌘←")
        XCTAssertEqual(ShortcutLabel.text(key: .downArrow, modifiers: [.command, .control, .shift]), "⌃⇧⌘↓")
        XCTAssertEqual(ShortcutLabel.text(key: .f2, modifiers: []), "F2")
    }

    func testThePaletteTakesCommandKAndClearNotificationsMoves() {
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.commandPalette.key, modifiers: ViewCommand.commandPalette.modifiers), "⌘K")
        XCTAssertEqual(
            ShortcutLabel.text(key: ViewCommand.clearNotifications.key, modifiers: ViewCommand.clearNotifications.modifiers), "⇧⌘K"
        )
    }

    /// Every menu-bar shortcut flock sets, from every list, is distinct.
    func testNoTwoMenuShortcutsCollide() {
        var labels = ViewCommand.allCases.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += FocusedPaneCommand.all.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers) }
        labels += PaneDirectionCommand.all.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += ChatMenuItem.allCases.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: [.command, .shift]) }
        labels += ["⌥⌘M", "F2", "⌘Z", "⇧⌘Z"]
        XCTAssertEqual(labels.count, Set(labels).count, "duplicates: \(labels.filter { label in labels.filter { $0 == label }.count > 1 })")
    }

    func testTheRightClickToggleIsTitledForWhatItWillDo() {
        XCTAssertEqual(RightClickToggle.title(for: .program), "Give Right-Clicks to Flock")
        XCTAssertEqual(RightClickToggle.title(for: .menu), "Send Right-Clicks to Program")
    }
}
```

- [ ] **Step 2: Move `PaneDirectionCommand` and `KeyEquivalent.f2` out of `FlockApp.swift`**

`FlockChromeRender` compiles `Sources/Flock` without `FlockApp.swift`, so anything a test or the palette reads must live elsewhere. Cut `struct PaneDirectionCommand { ... }` (with its doc comment, from `/// One directional pane command` through its closing brace) and `extension KeyEquivalent { static let f2 = KeyEquivalent("\u{F705}") }` (with its doc comment) out of `FlockApp.swift` into a new `Sources/Flock/Menus/PaneDirectionCommand.swift` that starts with `import FlockCore` and `import SwiftUI`. Change nothing else in them. Run `xcodegen`.

- [ ] **Step 2b: Run the tests to see them fail**

Run: `xcodegen`, then `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/PaletteShortcutTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, `ShortcutLabel`, `ViewCommand`, `RightClickToggle` not found.

- [ ] **Step 3: Write `ShortcutLabel` and `ViewCommand`**

`Sources/Flock/Menus/ShortcutLabel.swift`:

```swift
import AppKit
import SwiftUI

/// A shortcut as macOS writes it in a menu: modifiers in ⌃⌥⇧⌘ order, then the key.
enum ShortcutLabel {
    static func text(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + keyText(key)
    }

    private static func keyText(_ key: KeyEquivalent) -> String {
        switch key {
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .return: return "↩"
        default: break
        }
        if let scalar = key.character.unicodeScalars.first, scalar.value == UInt32(NSF2FunctionKey) { return "F2" }
        return String(key.character).uppercased()
    }
}

/// The right-click toggle, titled for what choosing it will do.
enum RightClickToggle {
    static func title(for mode: RightClickMode?) -> String {
        mode == .program ? "Give Right-Clicks to Flock" : "Send Right-Clicks to Program"
    }
}
```

Add `import FlockCore` at the top of `ShortcutLabel.swift` (it reads `RightClickMode`).

`Sources/Flock/Menus/ViewCommand.swift`:

```swift
import SwiftUI

/// The File and View menus' one-step items, each with its title and
/// shortcut, read by the menu bar and the palette alike.
enum ViewCommand: String, CaseIterable {
    case newTab, newWorkspace, rearrangeMode, allWorkspaces, openOldestNotification, clearNotifications, commandPalette

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWorkspace: "New Workspace"
        case .rearrangeMode: "Rearrange Mode"
        case .allWorkspaces: "All Workspaces"
        case .openOldestNotification: "Open Oldest Notification"
        case .clearNotifications: "Clear Notifications"
        case .commandPalette: "Command Palette…"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newTab: "t"
        case .newWorkspace: "n"
        case .rearrangeMode: KeyEquivalent(ArrangeShortcut.rearrangeMode.key)
        case .allWorkspaces: KeyEquivalent(ArrangeShortcut.allWorkspaces.key)
        case .openOldestNotification: "j"
        case .clearNotifications, .commandPalette: "k"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newTab, .openOldestNotification, .commandPalette: .command
        case .newWorkspace, .clearNotifications: [.command, .shift]
        case .rearrangeMode: ArrangeShortcut.rearrangeMode.modifiers
        case .allWorkspaces: ArrangeShortcut.allWorkspaces.modifiers
        }
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    var accessibilityIdentifier: String {
        switch self {
        case .newTab: "flock.file.newTab"
        case .newWorkspace: "flock.file.newWorkspace"
        case .rearrangeMode: "flock.view.rearrangeMode"
        case .allWorkspaces: "flock.view.allWorkspaces"
        case .openOldestNotification: "flock.view.openOldestNotification"
        case .clearNotifications: "flock.view.clearNotifications"
        case .commandPalette: "flock.view.commandPalette"
        }
    }
}
```

These are the identifiers the menu items carry today; keep them.

- [ ] **Step 4: Point the menus at `ViewCommand` and add the palette item**

In `FlockApp.swift`:

1. Add, next to the other `@State` stores: `@State private var commandPalette = CommandPaletteState()` and `@State private var paletteRecents = PaletteRecentsStore()`, and add `.environment(commandPalette)` and `.environment(paletteRecents)` after `.environment(dividerDragCoordinator)`.
2. In `CommandGroup(replacing: .newItem)`, replace the literal titles and shortcuts: `Button(ViewCommand.newTab.title)` with `.keyboardShortcut(ViewCommand.newTab.shortcut)` and `.accessibilityIdentifier(ViewCommand.newTab.accessibilityIdentifier)`; the same for `.newWorkspace`.
3. In the View menu group, do the same for Rearrange Mode (keep its checkmark label, use `ViewCommand.rearrangeMode.title` in both branches), All Workspaces (same), Open Oldest Notification and Clear Notifications. Clear Notifications now reads `.keyboardShortcut(ViewCommand.clearNotifications.shortcut)`, which is ⇧⌘K.
4. Directly before the ThemeMenu line, add:

```swift
                Button(ViewCommand.commandPalette.title) { commandPalette.toggle() }
                    .keyboardShortcut(ViewCommand.commandPalette.shortcut)
                    // The rename field keeps ⌘K while it is open.
                    .disabled(viewModel.renameEditorIsOnScreen)
                    .accessibilityIdentifier(ViewCommand.commandPalette.accessibilityIdentifier)
                Divider()
```

5. The right-click toggle button's title becomes `Button(RightClickToggle.title(for: viewModel.focusedPaneRightClickMode))`.

- [ ] **Step 5: Lift chat's `perform` onto `ChatMenuItem`**

In `ChatCommands.swift`, delete `private func perform(_ item: ChatMenuItem)` from `ChatCommands`, make its button call `row.item.perform(chatStore: chatStore, viewModel: viewModel)`, and add after the `ChatMenuItem` enum:

```swift
extension ChatMenuItem {
    /// Chat Panel opens the popover's status root, since that IS the panel;
    /// Broadcast, Peek and Quick Send each land directly on their own
    /// sub-view -- a shortcut names an action, so it must deliver that
    /// action, not a launcher the user still has to navigate.
    @MainActor
    func perform(chatStore: ChatStore, viewModel: SessionViewModel) {
        guard let pane = viewModel.resolvedFocusedPaneID else { return }
        switch self {
        case .chatPanel:
            chatStore.requestPopover(for: pane)
        case .broadcast:
            chatStore.requestPopover(for: pane, feature: .broadcast)
        case .peek:
            chatStore.requestPopover(for: pane, feature: .peek)
        case .quickSend:
            chatStore.requestPopover(for: pane, feature: .quickSend)
        case .openViewer:
            Task {
                guard let url = await chatStore.viewerURL(room: nil) else { return }
                NSWorkspace.shared.open(url)
            }
        case .signIn:
            Task { await chatStore.signIn(pane) }
        case .signOut:
            Task { await chatStore.signOut(pane) }
        }
    }
}
```

- [ ] **Step 6: README**

In `README.md`'s Keyboard shortcuts table, add a row after New Workspace: `| <kbd>⌘</kbd><kbd>K</kbd> | Command palette |`, and change the Clear notifications row to `| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd> | Clear notifications |`.

- [ ] **Step 7: Run the tests, then both suites**

Run the Step 2 command. Expected: 4 pass. Then the full FlockCoreTests and FlockChromeRender suites; expected: all pass (the chat menu tests still see the same rows).

- [ ] **Step 8: Commit**

```bash
git add Sources/Flock/Menus/ViewCommand.swift Sources/Flock/Menus/ShortcutLabel.swift Sources/Flock/Menus/PaneDirectionCommand.swift Sources/Flock/FlockApp.swift Sources/Flock/Chat/ChatCommands.swift README.md Tests/FlockChromeRender/PaletteShortcutTests.swift
Scripts/checks.sh
git commit -m "menus: view commands in one list, ⌘K opens the palette, Clear Notifications to ⇧⌘K" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: What the palette lists right now (app)

**Files:**
- Create: `Sources/Flock/Palette/PaletteCatalog.swift`
- Test: `Tests/FlockChromeRender/PaletteCatalogTests.swift`

**Interfaces:**
- Consumes: `PaletteCommand`, `PaletteNamespace` (Task 1); `ViewCommand`, `ShortcutLabel`, `RightClickToggle` (Task 4); existing `FocusedPaneCommand.all`, `PaneDirectionCommand.all`, `ChatMenuModel.Row`, `ChatMenuItem`, `RtCommandRow`, `RtKind`, `PaneMenuAction`, `PaneDirection`, `RightClickMode`, `ChatButtonModel.claudeAgent`.
- Produces:
  - `struct PaletteContext { var canvasPane: PaneID?; var neighbors: Set<PaneDirection>; var rtModalUp: Bool; var rtInstalled: Bool; var rtCommands: [RtCommandRow]; var chatRows: [ChatMenuModel.Row]?; var focusedAgent: String?; var rightClickMode: RightClickMode?; var programHasMouse: Bool; var hasSelectedWorkspace: Bool; var hasNotifications: Bool }` with a memberwise init where every property has a default (`nil`, `[]`, `false`)
  - `enum PaletteAction { case paneMenu(PaneMenuAction), direction(PaneDirectionCommand), chat(ChatMenuItem), rt(RtKind), toggleRightClicks, view(ViewCommand) }`
  - `struct PaletteEntry { let command: PaletteCommand; let action: PaletteAction }`
  - `enum PaletteCatalog { static func entries(in context: PaletteContext) -> [PaletteEntry] }`

`rtCommands` is empty when the focused pane has no terminal; the caller fills it from `viewModel.rt.commandRows(linkedTo:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlockChromeRender/PaletteCatalogTests.swift`:

```swift
import XCTest
@testable import FlockCore

@MainActor
final class PaletteCatalogTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")
    private let rtRows = RtPopoverModel.commands(hasRunner: false)
    private let chatRows = ChatMenuItem.allCases.map { ChatMenuModel.Row(item: $0, isEnabled: $0 != .signOut) }

    private func ids(_ context: PaletteContext) -> [String] {
        PaletteCatalog.entries(in: context).map(\.command.id)
    }

    func testAPlainShellPaneListsPaneRtViewAndCreationButNoChatOrMouse() {
        let listed = ids(PaletteContext(
            canvasPane: pane, neighbors: [.right], rtInstalled: true, rtCommands: rtRows, chatRows: chatRows,
            rightClickMode: .program, hasSelectedWorkspace: true
        ))
        XCTAssertTrue(listed.contains("rt.glitter"))
        XCTAssertTrue(listed.contains("pane.splitright"))
        XCTAssertTrue(listed.contains("pane.focuspaneright"))
        XCTAssertFalse(listed.contains("pane.focuspaneleft"), "no neighbor to the left")
        XCTAssertFalse(listed.contains { $0.hasPrefix("chat.") }, "a shell pane is not running Claude Code")
        XCTAssertFalse(listed.contains("mouse.rightclicks"), "the program has not claimed the mouse")
        XCTAssertTrue(listed.contains("view.rearrangemode"))
        XCTAssertTrue(listed.contains("tab.newtab"))
        XCTAssertTrue(listed.contains("workspace.newworkspace"))
        XCTAssertFalse(listed.contains("view.clearnotifications"), "nothing to clear")
    }

    func testAClaudePaneWithTheMouseListsChatAndTheToggle() {
        let entries = PaletteCatalog.entries(in: PaletteContext(
            canvasPane: pane, chatRows: chatRows, focusedAgent: ChatButtonModel.claudeAgent,
            rightClickMode: .program, programHasMouse: true
        ))
        let listed = entries.map(\.command.id)
        XCTAssertTrue(listed.contains("chat.quicksend"))
        XCTAssertFalse(listed.contains("chat.signoutthispane"), "a disabled chat row is not listed")
        XCTAssertEqual(entries.first { $0.command.id == "mouse.rightclicks" }?.command.name, "Give Right-Clicks to Flock")
    }

    func testRtRowsAreNamedByVerbWithThePopoverTitleAsHint() {
        let entry = PaletteCatalog.entries(in: PaletteContext(canvasPane: pane, rtInstalled: true, rtCommands: rtRows))
            .first { $0.command.id == "rt.glitter" }
        XCTAssertEqual(entry?.command.name, "glitter")
        XCTAssertEqual(entry?.command.hint, "Review and commit")
        XCTAssertNil(entry?.command.shortcut)
    }

    func testNoRtRowsWithoutRt() {
        XCTAssertFalse(ids(PaletteContext(canvasPane: pane, rtInstalled: false, rtCommands: rtRows)).contains { $0.hasPrefix("rt.") })
    }

    /// Over the rt modal the canvas has no focused pane, as the menus see it.
    func testWhileTheRtModalIsUpNoPaneCommandsAreListed() {
        let listed = ids(PaletteContext(canvasPane: nil, neighbors: [.left, .right], rtModalUp: true, rtInstalled: true, rtCommands: rtRows))
        XCTAssertFalse(listed.contains { $0.hasPrefix("pane.") })
        XCTAssertTrue(listed.contains("rt.glitter"))
    }

    func testShortcutsReadAsTheMenusShowThem() {
        let entries = PaletteCatalog.entries(in: PaletteContext(canvasPane: pane, neighbors: [.left], hasNotifications: true))
        let shortcut = { (id: String) in entries.first { $0.command.id == id }?.command.shortcut }
        XCTAssertEqual(shortcut("pane.splitright"), "⌘D")
        XCTAssertEqual(shortcut("pane.focuspaneleft"), "⌥⌘←")
        XCTAssertEqual(shortcut("pane.renamepane"), "F2")
        XCTAssertEqual(shortcut("view.clearnotifications"), "⇧⌘K")
        XCTAssertFalse(entries.contains { $0.command.id == "view.commandpalette" }, "the palette does not list itself")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodegen`, then `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/PaletteCatalogTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, `PaletteCatalog` not found.

- [ ] **Step 3: Write the code**

`Sources/Flock/Palette/PaletteCatalog.swift`:

```swift
import FlockCore
import SwiftUI

/// What the palette may offer at one moment, as plain values, so the rules
/// are testable without a window. Each rule is the one the command's own
/// menu item or button uses.
struct PaletteContext {
    var canvasPane: PaneID? = nil
    var neighbors: Set<PaneDirection> = []
    var rtModalUp = false
    var rtInstalled = false
    var rtCommands: [RtCommandRow] = []
    var chatRows: [ChatMenuModel.Row]? = nil
    var focusedAgent: String? = nil
    var rightClickMode: RightClickMode? = nil
    var programHasMouse = false
    var hasSelectedWorkspace = false
    var hasNotifications = false
}

enum PaletteAction {
    case paneMenu(PaneMenuAction)
    case direction(PaneDirectionCommand)
    case chat(ChatMenuItem)
    case rt(RtKind)
    case toggleRightClicks
    case view(ViewCommand)
}

struct PaletteEntry {
    let command: PaletteCommand
    let action: PaletteAction
}

enum PaletteCatalog {
    static func entries(in context: PaletteContext) -> [PaletteEntry] {
        rt(context) + pane(context) + chat(context) + mouse(context) + view(context)
    }

    /// Stable across launches while a title stands still, which is all recents need.
    static func id(_ namespace: PaletteNamespace, _ title: String) -> String {
        namespace.rawValue + "." + title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func entry(_ namespace: PaletteNamespace, _ name: String, shortcut: String? = nil, hint: String? = nil,
                              id: String? = nil, _ action: PaletteAction) -> PaletteEntry {
        PaletteEntry(
            command: PaletteCommand(id: id ?? Self.id(namespace, name), namespace: namespace, name: name, shortcut: shortcut, hint: hint),
            action: action
        )
    }

    private static func rt(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rtInstalled else { return [] }
        return context.rtCommands.map { entry(.rt, $0.kind.rawValue, hint: $0.title, .rt($0.kind)) }
    }

    private static func pane(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.canvasPane != nil else { return [] }
        let menu = FocusedPaneCommand.all.map {
            entry(.pane, $0.title, shortcut: ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers), .paneMenu($0.action))
        }
        let extras = [
            entry(.pane, "Zoom Pane", .paneMenu(.zoom)),
            entry(.pane, "Rename Pane", shortcut: ShortcutLabel.text(key: .f2, modifiers: []), .paneMenu(.renamePane)),
        ]
        let directions = PaneDirectionCommand.all
            .filter { context.neighbors.contains($0.direction) && !context.rtModalUp }
            .map { entry(.pane, $0.title, shortcut: ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers), .direction($0)) }
        return menu + extras + directions
    }

    private static func chat(_ context: PaletteContext) -> [PaletteEntry] {
        guard let rows = context.chatRows, context.focusedAgent == ChatButtonModel.claudeAgent else { return [] }
        return rows.filter(\.isEnabled).map {
            entry(.chat, $0.item.title, shortcut: ShortcutLabel.text(key: KeyEquivalent($0.item.key), modifiers: [.command, .shift]), .chat($0.item))
        }
    }

    private static func mouse(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rightClickMode != nil, context.programHasMouse else { return [] }
        return [entry(
            .mouse, RightClickToggle.title(for: context.rightClickMode), shortcut: "⌥⌘M", id: "mouse.rightclicks", .toggleRightClicks
        )]
    }

    private static func view(_ context: PaletteContext) -> [PaletteEntry] {
        let shortcut = { (command: ViewCommand) in ShortcutLabel.text(key: command.key, modifiers: command.modifiers) }
        var commands: [(PaletteNamespace, ViewCommand)] = [(.view, .rearrangeMode), (.view, .allWorkspaces)]
        if context.hasNotifications { commands += [(.view, .openOldestNotification), (.view, .clearNotifications)] }
        if context.hasSelectedWorkspace { commands.append((.tab, .newTab)) }
        commands.append((.workspace, .newWorkspace))
        return commands.map { entry($0.0, $0.1.title, shortcut: shortcut($0.1), .view($0.1)) }
    }
}
```

- [ ] **Step 4: Run the tests**

Run the Step 2 command. Expected: 6 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Flock/Palette/PaletteCatalog.swift Tests/FlockChromeRender/PaletteCatalogTests.swift
Scripts/checks.sh
git commit -m "palette: the commands it lists, from the menus' own lists and rules" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The palette view, its keys and its wiring (app)

**Files:**
- Create: `Sources/Flock/Palette/CommandPaletteView.swift`
- Create: `Sources/Flock/Palette/PaletteKeyMonitor.swift`
- Create: `Sources/Flock/Palette/PaletteRunner.swift`
- Modify: `Sources/Flock/Views/MainWindow.swift` (overlay after `RtModalView`)
- Modify: `Sources/Flock/Views/PaneCellView.swift`, `Sources/Flock/Rt/RtModalPane.swift`, `Sources/Flock/Rt/RtModalView.swift` (the palette counts as an open editor)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift`, `Sources/Flock/Theme/ChromeTypography.swift`
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (Harness gains the two stores; new render tests)

**Interfaces:**
- Consumes: everything above; `HoverWash` (`hoverWash(_:cornerRadius:)`), `ChromeMetrics.RtModal.lightBackdropOpacity` / `darkBackdropOpacity`, `RtAvailability.installed`, `viewModel.rt.commandRows(linkedTo:)`, `viewModel.ghosttySurface(for:)`, `viewModel.focusedPaneHasNeighbor(toward:)`.
- Produces: `CommandPaletteView(theme:viewModel:)`; `PaletteContext.current(viewModel:chatStore:rtInstalled:)`; `PaletteRunner(viewModel:chatStore:rearrangeMode:dragCoordinator:).run(_:)`.

- [ ] **Step 1: Metrics and type**

In `ChromeMetrics.swift`, add:

```swift
    /// The command palette over the tab area.
    enum Palette {
        static let width: CGFloat = 520
        static let top: CGFloat = 44
        static let cornerRadius: CGFloat = 10
        static let shadowRadius: CGFloat = 16
        static let shadowY: CGFloat = 12
        static let shadowOpacity: Double = 0.35
        static let searchHeight: CGFloat = 44
        static let searchPadding: CGFloat = 14
        static let searchGap: CGFloat = 10
        static let searchIcon: CGFloat = 15
        static let listPadding: CGFloat = 6
        static let rowHeight: CGFloat = 32
        static let rowPadding: CGFloat = 8
        static let rowGap: CGFloat = 10
        static let rowCornerRadius: CGFloat = 6
        static let badgeSize = CGSize(width: 44, height: 18)
        static let badgeCornerRadius: CGFloat = 4
        static let sectionPadding = EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8)
        static let footerHeight: CGFloat = 30
        static let footerGap: CGFloat = 14
        static let maxListHeight: CGFloat = 360
    }
```

In `ChromeTypography.swift`, add: `static let paletteSearch = inter(14)`, `static let paletteName = inter(13)`, `static let paletteNameSelected = inter(13, .medium)`, `static let paletteShortcut = inter(12)`, `static let paletteBadge = inter(10.5, .semibold)`, `static let paletteSection = inter(10, .semibold)`, `static let paletteFooter = inter(11)`.

- [ ] **Step 2: The runner and the context**

`Sources/Flock/Palette/PaletteRunner.swift`:

```swift
import FlockCore
import SwiftUI

extension PaletteContext {
    /// This moment, read the way each command's own menu item or button reads it.
    @MainActor
    static func current(viewModel: SessionViewModel, chatStore: ChatStore, rtInstalled: Bool) -> PaletteContext {
        let focused = viewModel.resolvedFocusedPaneID
        let record = focused.flatMap { viewModel.model?.panes[$0] }
        let terminal = record?.terminalID
        return PaletteContext(
            canvasPane: viewModel.canvasFocusedPaneID,
            neighbors: Set(PaneDirection.allCases.filter { viewModel.focusedPaneHasNeighbor(toward: $0) }),
            rtModalUp: viewModel.rt.modal != nil,
            rtInstalled: rtInstalled && terminal != nil,
            rtCommands: terminal.map { viewModel.rt.commandRows(linkedTo: $0) } ?? [],
            chatRows: ChatMenuModel.rows(
                isAvailable: chatStore.isAvailable, hasFocusedPane: focused != nil,
                isSignedIn: focused.flatMap { chatStore.status(for: $0) }?.signedIn ?? false,
                viewerDisabledReason: chatStore.viewerDisabledReason
            ),
            focusedAgent: record?.agent,
            rightClickMode: viewModel.focusedPaneRightClickMode,
            programHasMouse: focused.flatMap { viewModel.ghosttySurface(for: $0) }?.programHasMouse ?? false,
            hasSelectedWorkspace: viewModel.selectedWorkspaceID != nil,
            hasNotifications: !viewModel.attentionToasts.isEmpty
        )
    }
}

/// Runs a palette row the way its menu item or button does.
@MainActor
struct PaletteRunner {
    let viewModel: SessionViewModel
    let chatStore: ChatStore
    let rearrangeMode: RearrangeMode
    let dragCoordinator: DragCoordinator

    func run(_ action: PaletteAction) {
        switch action {
        case .paneMenu(let paneAction):
            guard let pane = viewModel.canvasFocusedPaneID else { return }
            Task { await paneAction.perform(paneID: pane, on: viewModel) }
        case .direction(let command):
            Task {
                switch command.kind {
                case .focus: await viewModel.focusNeighbor(toward: command.direction)
                case .move: await viewModel.moveFocusedPane(toward: command.direction)
                case .swap: await viewModel.swapFocusedPane(toward: command.direction)
                }
            }
        case .chat(let item):
            item.perform(chatStore: chatStore, viewModel: viewModel)
        case .rt(let kind):
            guard let pane = viewModel.resolvedFocusedPaneID, let record = viewModel.fullModel?.panes[pane] else { return }
            Task { await viewModel.rt.open(kind, from: record) }
        case .toggleRightClicks:
            viewModel.toggleFocusedPaneRightClicks()
        case .view(let command):
            switch command {
            case .newTab:
                guard let workspace = viewModel.selectedWorkspaceID else { return }
                Task { await viewModel.createTab(in: workspace) }
            case .newWorkspace: Task { await viewModel.createWorkspace() }
            case .rearrangeMode: rearrangeMode.toggle()
            case .allWorkspaces: dragCoordinator.toggleGrid()
            case .openOldestNotification: Task { await viewModel.jumpToOldestDisplayedAttentionToast() }
            case .clearNotifications: viewModel.clearAttentionToasts()
            case .commandPalette: break
            }
        }
    }
}
```

Make `FlockApp.swift`'s File and View menu buttons call `PaletteRunner(...).run(.view(...))` only if that removes duplication without changing their disabled rules; otherwise leave them calling their actions directly (Task 4 already made their titles and keys shared).

- [ ] **Step 3: The key monitor**

`Sources/Flock/Palette/PaletteKeyMonitor.swift`, following `RtModalKeyMonitor`:

```swift
import AppKit
import FlockCore
import SwiftUI

/// Takes ↑ ↓ ⌃P ⌃N Return and Esc while the palette is up, before the search
/// field or a pane sees them.
struct PaletteKeyMonitor: NSViewRepresentable {
    let onDecision: (PaletteKey.Decision) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onDecision = onDecision
    }

    final class MonitorView: NSView {
        var onDecision: (PaletteKey.Decision) -> Void = { _ in }
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                let flags = event.modifierFlags
                let decision = PaletteKey.decide(
                    keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                    control: flags.contains(.control), command: flags.contains(.command)
                )
                guard decision != .pass else { return event }
                self.onDecision(decision)
                return nil
            }
        }
    }
}
```

- [ ] **Step 4: The view**

`Sources/Flock/Palette/CommandPaletteView.swift`:

```swift
import FlockCore
import SwiftUI

/// The command palette over the tab area: a scrim that closes it on a click,
/// and near the top a box holding the search field, the rows and a footer.
/// Draws nothing while closed.
struct CommandPaletteView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(CommandPaletteState.self) private var state
    @Environment(PaletteRecentsStore.self) private var recents
    @Environment(ChatStore.self) private var chatStore
    @Environment(RearrangeMode.self) private var rearrangeMode
    @Environment(DragCoordinator.self) private var dragCoordinator
    @FocusState private var searchFocused: Bool

    var rtInstalled = RtAvailability.installed

    private typealias Metrics = ChromeMetrics.Palette

    var body: some View {
        if state.isOpen {
            let entries = PaletteCatalog.entries(
                in: .current(viewModel: viewModel, chatStore: chatStore, rtInstalled: rtInstalled)
            )
            let rows = PaletteRanking.rows(commands: entries.map(\.command), query: state.query, recents: recents.ids)
            ZStack(alignment: .top) {
                scrim
                box(rows: rows, entries: entries)
                    .padding(.top, Metrics.top)
            }
            .background(PaletteKeyMonitor { decision in handle(decision, rows: rows, entries: entries) })
            .onChange(of: rows.count, initial: true) { _, count in state.clampSelection(rowCount: count) }
            .onAppear { searchFocused = true }
        }
    }

    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.RtModal.lightBackdropOpacity : ChromeMetrics.RtModal.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture { state.close() }
    }

    private func box(rows: [PaletteRanking.Row], entries: [PaletteEntry]) -> some View {
        VStack(spacing: 0) {
            search
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            list(rows: rows, entries: entries)
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            footer
        }
        .frame(width: Metrics.width)
        .background(theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        .accessibilityIdentifier("flock.palette")
    }

    private var search: some View {
        @Bindable var state = state
        return HStack(spacing: Metrics.searchGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.searchIcon - 2))
                .foregroundStyle(theme.textLabel)
            TextField("", text: $state.query, prompt: Text("Search commands").foregroundStyle(theme.textLabel))
                .textFieldStyle(.plain)
                .font(ChromeType.paletteSearch)
                .foregroundStyle(theme.textStrong)
                .focused($searchFocused)
                .accessibilityIdentifier("flock.palette.search")
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.searchHeight)
    }

    @ViewBuilder
    private func list(rows: [PaletteRanking.Row], entries: [PaletteEntry]) -> some View {
        if rows.isEmpty {
            Text("No matching commands")
                .font(ChromeType.paletteName)
                .foregroundStyle(theme.textLabel)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight * 2)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if row.section != nil, index == 0 || rows[index - 1].section != row.section {
                            section(row.section == .recent ? "RECENT" : "ALL COMMANDS")
                        }
                        rowView(row, selected: index == state.selectedIndex(rowCount: rows.count))
                            .onTapGesture { runRow(at: index, rows: rows, entries: entries) }
                    }
                }
                .padding(Metrics.listPadding)
            }
            .frame(maxHeight: Metrics.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(ChromeType.paletteSection)
            .tracking(0.8)
            .foregroundStyle(theme.textLabel)
            .padding(Metrics.sectionPadding)
    }

    private func rowView(_ row: PaletteRanking.Row, selected: Bool) -> some View {
        HStack(spacing: Metrics.rowGap) {
            Text(row.command.namespace.rawValue)
                .font(ChromeType.paletteBadge)
                .foregroundStyle(theme.textLabel)
                .frame(width: Metrics.badgeSize.width, height: Metrics.badgeSize.height)
                .background(RoundedRectangle(cornerRadius: Metrics.badgeCornerRadius).fill(badgeFill))
            highlighted(row)
                .font(selected ? ChromeType.paletteNameSelected : ChromeType.paletteName)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing = row.command.shortcut ?? row.command.hint {
                Text(trailing).font(ChromeType.paletteShortcut).foregroundStyle(theme.textLabel)
            }
        }
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius).fill(selected ? theme.selection : .clear))
        .hoverWash(theme, cornerRadius: Metrics.rowCornerRadius)
        .contentShape(Rectangle())
        .accessibilityIdentifier("flock.palette.row.\(row.command.id)")
    }

    private var badgeFill: Color {
        ChromeRoles.isLight(panelBg: theme.palette.panelBg) ? Color(theme.palette.surface1) : Color(theme.palette.surface0)
    }

    private func highlighted(_ row: PaletteRanking.Row) -> Text {
        let matched = Set(row.nameIndices)
        var text = AttributedString()
        for (offset, character) in row.command.name.enumerated() {
            var piece = AttributedString(String(character))
            piece.foregroundColor = matched.contains(offset) ? theme.accent : theme.textStrong
            text += piece
        }
        return Text(text)
    }

    private var footer: some View {
        HStack(spacing: Metrics.footerGap) {
            ForEach(["↑↓ move", "↵ run", "esc close"], id: \.self) { hint in
                Text(hint).font(ChromeType.paletteFooter).foregroundStyle(theme.textLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.searchPadding)
        .frame(height: Metrics.footerHeight)
    }

    private func handle(_ decision: PaletteKey.Decision, rows: [PaletteRanking.Row], entries: [PaletteEntry]) {
        switch decision {
        case .up: state.move(-1, rowCount: rows.count)
        case .down: state.move(1, rowCount: rows.count)
        case .close: state.close()
        case .run:
            guard let index = state.selectedIndex(rowCount: rows.count) else { return }
            runRow(at: index, rows: rows, entries: entries)
        case .pass: break
        }
    }

    /// Closed before the action runs, so a command that opens its own UI
    /// (the rename editor, a chat popover) gets the focus.
    private func runRow(at index: Int, rows: [PaletteRanking.Row], entries: [PaletteEntry]) {
        guard rows.indices.contains(index), let entry = entries.first(where: { $0.command.id == rows[index].command.id }) else { return }
        state.close()
        recents.record(entry.command.id)
        PaletteRunner(viewModel: viewModel, chatStore: chatStore, rearrangeMode: rearrangeMode, dragCoordinator: dragCoordinator)
            .run(entry.action)
    }
}
```

- [ ] **Step 5: Wire it in**

1. `MainWindow.swift`: after `.overlay { RtModalView(theme: theme, viewModel: viewModel) }`, add `.overlay { CommandPaletteView(theme: theme, viewModel: viewModel) }`.
2. `PaneCellView.swift` line `let editorIsOpen = viewModel.renameEditorIsOnScreen`: add `@Environment(CommandPaletteState.self) private var commandPalette` to the view and make it `let editorIsOpen = viewModel.renameEditorIsOnScreen || commandPalette.isOpen`. Do the same in `RtModalPane.swift`. In `RtModalView.swift`, the key monitor's `stripShown` becomes `item.strip != nil && !viewModel.renameEditorIsOnScreen && !commandPalette.isOpen` (add the same environment property).
3. Every preview or test harness that builds these views needs the two environment objects. In `Tests/FlockChromeRender/ChromeRenderTests.swift`'s `Harness`, add `let palette = CommandPaletteState()` and `let paletteRecents: PaletteRecentsStore` (built from the harness's `defaults`), and `.environment(palette)` / `.environment(paletteRecents)` in `makeWindow`. Search `Tests/FlockChromeRender` for every other `.environment(rearrangeMode)` or `.environment(rearrange)` and add the two there as well, or the render suite crashes on a missing environment object.

- [ ] **Step 6: Render tests**

Add to `ChromeRenderTests` (use the file's `settle`, `snapshot`, `hex`, `firstPixel` and `click` helpers):

```swift
    /// The palette over the window, empty and with a typed query, in both
    /// themes: its ground, a selected first row, and the match highlight.
    func testThePaletteDrawsOverTheTabAreaWithItsRowsAndHighlight() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            harness.palette.open()
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let empty = try snapshot(window)
            harness.palette.query = "rearr"
            await settle(window)
            let typed = try snapshot(window)
            if let directory {
                for (name, image) in [("empty", empty), ("typed", typed)] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("palette-\(name)-\(id).png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            // Right of the rail, whose selected workspace row shares the selection colour.
            let left = try XCTUnwrap(harness.drag.canvas.paneFrames.values.map(\.minX).min())
            let box = CGRect(x: left, y: 0, width: 900 - left, height: 400)
            XCTAssertNotNil(firstPixel(empty, in: box, matching: theme.palette.chromeRoles.selection.hex), "\(id): no selected row")
            XCTAssertNotNil(firstPixel(typed, in: box, matching: theme.palette.accent.hex), "\(id): no highlighted letters")
            window.close()
        }
    }

    /// A click on a row runs it and closes the palette first.
    func testClickingARowRunsItAndClosesThePalette() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        harness.palette.query = "rearrange"
        let window = harness.makeWindow(size: Self.windowSize)
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        let image = try snapshot(window)
        // Right of the rail, whose selected workspace row shares the selection colour.
        let canvas = try XCTUnwrap(harness.drag.canvas.paneFrames.values.map(\.minX).min())
        let row = try XCTUnwrap(
            firstPixel(image, in: CGRect(x: canvas, y: 0, width: 900 - canvas, height: 400), matching: Theme.tokyoNight.palette.chromeRoles.selection.hex)
        )
        click(window, at: row)
        await settle(window)
        XCTAssertFalse(harness.palette.isOpen)
        XCTAssertTrue(harness.rearrange.isToggled)
        XCTAssertEqual(harness.paletteRecents.ids.first, "view.rearrangemode")
        window.close()
    }
```

- [ ] **Step 7: Run, look, run everything**

Run: `xcodegen`, then `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=<dir> xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ChromeRenderTests/testThePaletteDrawsOverTheTabAreaWithItsRowsAndHighlight -only-testing:FlockChromeRender/ChromeRenderTests/testClickingARowRunsItAndClosesThePalette -skipPackagePluginValidation -derivedDataPath <scratch>`.
Expected: both pass. Open the four PNGs and check against `docs/design/palette/palette-dark.png` and `palette-light.png`: box width and position, badge chips neutral, shortcut column aligned, section labels, the highlight in the accent, the footer. Fix any mismatch before going on.
Then run the full FlockCoreTests and FlockChromeRender suites and `Scripts/checks.sh`. Expected: all pass.

- [ ] **Step 8: Commit and hand over**

```bash
git add Sources/Flock/Palette Sources/Flock/Views/MainWindow.swift Sources/Flock/Views/PaneCellView.swift Sources/Flock/Rt/RtModalPane.swift Sources/Flock/Rt/RtModalView.swift Sources/Flock/Theme/ChromeMetrics.swift Sources/Flock/Theme/ChromeTypography.swift Tests/FlockChromeRender
Scripts/checks.sh
git commit -m "palette: ⌘K opens it over the tab area" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
Scripts/dev-build.sh
```
