# Mission control and Arrange Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** give the All Workspaces view two modes: Mission control (live lanes of what every agent is doing and what needs you, with ⌘J / ⇧⌘J to jump in and back) and Arrange (today's grid redrawn as fit-to-window islands with identity colours).

**Architecture:** every rule lives in FlockCore as pure, tested types: a status history recorder, the lane board, repo/branch reading, jump-back origins, the mode and cutoff stores, the identity palette and store, and the island layout. The app target only draws them: a new `MissionControlView`, a reworked `AllWorkspacesGrid`, and wiring in `SessionViewModel`, the View menu, the palette and Settings.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, xcodegen. macOS 26 SDK.

**Spec:** `docs/superpowers/specs/2026-10-06-mission-control-design.md`. Visual references: boards `05 · MC · Lanes` (and `05b` light) and `10 · Arrange · Islands`, sized as board `08`, in `docs/design/workspaces/flock-workspaces.pen` (open with the pencil MCP tools, never `Read`).

## Global Constraints

- Public repo: no employer, customer, ticket id or private host anywhere, commit messages included. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration, no history.
- Tests are hermetic: no rt, herdr, herdr-chat or deck processes, no `~/.mattstack`, no network. Temp directories are fine.
- `XCTestCase.setUp`/`tearDown` are not main-actor: statics a `@MainActor` test class reads there are `nonisolated`.
- New files: run `xcodegen` before building. After `git add`, run `Scripts/checks.sh`.
- Derived data lives inside the worktree: `-derivedDataPath build/dd` (a path containing "GitHub" trips the worktree guard).
- Run only the tests for what a task touches. The full suites run in CI.
- UI is not done until rendered in a dark and a light theme and looked at.
- Never quit, kill or launch Flock or Flock Dev; never `herdr server stop`.
- Status hues: working yellow, blocked red, done teal, idle green, unknown overlay0 (`StatusDot`). Identity hues never sit within 25 degrees of these.
- Dormant cutoff choices: 15, 30 (default), 60, 120 minutes. History window: 60 minutes.
- Keys: ⌘J Open Oldest Notification, ⇧⌘J Jump Back, ⇧⌘U Clear Notifications, ⇧⌘R All Workspaces.
- Thumbnail width in Arrange: 120pt floor, 200pt cap, chosen per window, never changed during a drag.

## Review Focus

1. A pane closes while it is the jump-back origin: ⇧⌘J must be disabled, never jump to a dead id (Task 5 test, Task 9 test).
2. ⌘J pressed in mission control with more cards than the dock would draw: it opens the oldest card of all, not the oldest the hidden dock would have drawn (Task 9 test).
3. A workspace with more tabs than fit across the window at 120pt: its island wraps tabs to a second row instead of overflowing (Task 8 test).
4. A folder outside any git repository, or a worktree whose `.git` is a file: repo and branch still read, never crash (Task 4 tests).
5. A theme whose status hues crowd the wheel (every builtin): the identity palette still yields 8 hues, each 25 degrees clear and 3:1 on the canvas (Task 7 test).

---

## File Structure

FlockCore (pure, tested):

- `Sources/FlockCore/Mission/PaneStatusHistory.swift`: per-pane status transitions over the last hour.
- `Sources/FlockCore/Mission/DormantCutoff.swift`: the cutoff choices and their Settings store.
- `Sources/FlockCore/Mission/MissionBoard.swift`: lane assignment, ordering, grouping, dormant workspaces, keyboard columns, age text.
- `Sources/FlockCore/Mission/RepoBranch.swift`: repo and branch from git's files, plus a per-folder cache.
- `Sources/FlockCore/Mission/JumpBack.swift`: the one-level jump origin.
- `Sources/FlockCore/Grid/AllWorkspacesMode.swift`: the two modes and the store that remembers the last one.
- `Sources/FlockCore/Theme/IdentityPalette.swift`: eight identity hues per theme.
- `Sources/FlockCore/Theme/WorkspaceIdentityStore.swift`: which hue each workspace has.
- `Sources/FlockCore/Grid/IslandLayout.swift`: fit-to-window thumbnail size and island packing.

App:

- `Sources/Flock/Views/MissionControl/MissionControlView.swift`: the three lanes.
- `Sources/Flock/Views/MissionControl/MissionCardView.swift`: one card and its timeline.
- `Sources/Flock/Menus/JumpNavigator.swift`: where a jump starts and how Jump Back returns.
- Modify `Sources/FlockCore/ViewModels/SessionViewModel.swift`, `Sources/Flock/Views/AllWorkspacesGrid.swift`, `Sources/Flock/Views/MainWindow.swift`, `Sources/Flock/FlockApp.swift`, `Sources/Flock/Menus/ViewCommand.swift`, `Sources/Flock/Palette/PaletteCatalog.swift`, `Sources/Flock/Palette/PaletteRunner.swift`, `Sources/Flock/Views/AttentionToastStack.swift`, `Sources/Flock/Drag/DragCoordinator+Grid.swift`, `Sources/Flock/Views/Settings/*`, `Sources/Flock/Theme/ChromeMetrics.swift`, `Sources/Flock/Theme/ChromeTypography.swift`.

Tests:

- `Tests/FlockCoreTests/MissionFixture.swift` (shared model builder), `PaneStatusHistoryTests.swift`, `DormantCutoffTests.swift`, `MissionBoardTests.swift`, `RepoBranchTests.swift`, `JumpBackTests.swift`, `AllWorkspacesModeTests.swift`, `IdentityPaletteTests.swift`, `WorkspaceIdentityStoreTests.swift`, `IslandLayoutTests.swift`, `MissionJumpTests.swift`.
- `Tests/FlockChromeRender/ChromeRenderTests.swift`: new mission-control and island render tests next to the grid ones (they share its private harness and `GridFixture`).

Commands used throughout (from the worktree root):

```bash
CORE() { xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:"FlockCoreTests/$1" -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -25; }
RENDER() { xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:"FlockChromeRender/$1" -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -25; }
```

---

## Milestone 1: the rules (FlockCore)

### Task 0: Worktree setup

**Files:** none tracked.

- [ ] **Step 1: Copy the gitignored inputs and the submodule**

```bash
M=/Users/matt/Documents/GitHub/flock
cp -cR "$M/Vendor/GhosttyKit.xcframework" "$M/Vendor/Sparkle" "$M/Vendor/libghostty.version" Vendor/
cp -c "$M"/Sources/Flock/Resources/herdr-* Sources/Flock/Resources/
git submodule update --init Vendor/ghostty
xcodegen
```

- [ ] **Step 2: Confirm the core tests build**

Run: `CORE RailSectionsTests`
Expected: `** TEST SUCCEEDED **`

### Task 1: PaneStatusHistory

**Files:**
- Create: `Sources/FlockCore/Mission/PaneStatusHistory.swift`
- Create: `Tests/FlockCoreTests/MissionFixture.swift`
- Test: `Tests/FlockCoreTests/PaneStatusHistoryTests.swift`

**Interfaces:**
- Produces: `PaneStatusHistory` with `observe(_ model: SessionModel, at: Date)`, `lastChange(of: PaneID) -> Date?`, `age(of: PaneID, at: Date) -> TimeInterval?`, `segments(of: PaneID, at: Date) -> [PaneStatusHistory.Segment]`, `static let window: TimeInterval`. `Segment(status: AgentStatus?, start: Date, end: Date)`, nil status meaning no record.
- Produces (test support): `MissionFixture.model(_ specs: [MissionFixture.Workspace], focusedPane: String? = nil) -> SessionModel`.

- [ ] **Step 1: Write the shared fixture**

```swift
import Foundation
@testable import FlockCore

/// Builds a `SessionModel` from a compact description. Workspace `w1` holds
/// tabs `w1:t1`, `w1:t2`...; tab `w1:t2` holds panes `w1:t2:p1`...
enum MissionFixture {
    struct Pane {
        let status: AgentStatus
        var title = "claude"
        var cwd = "/private/tmp"
    }

    struct Tab {
        let label: String
        let panes: [Pane]
    }

    struct Workspace {
        let label: String
        let tabs: [Tab]
    }

    static func model(_ specs: [Workspace], focusedPane: String? = nil) -> SessionModel {
        var workspaces: [WorkspaceRecord] = []
        var tabs: [TabRecord] = []
        var panes: [PaneRecord] = []
        for (w, spec) in specs.enumerated() {
            let workspaceID = WorkspaceID(rawValue: "w\(w + 1)")
            workspaces.append(WorkspaceRecord(
                workspaceID: workspaceID, label: spec.label, number: w + 1,
                activeTabID: TabID(rawValue: "w\(w + 1):t1"), agentStatus: .idle
            ))
            for (t, tab) in spec.tabs.enumerated() {
                let tabID = TabID(rawValue: "w\(w + 1):t\(t + 1)")
                tabs.append(TabRecord(
                    tabID: tabID, workspaceID: workspaceID, label: tab.label, number: t + 1,
                    paneCount: tab.panes.count, agentStatus: .idle
                ))
                for (p, pane) in tab.panes.enumerated() {
                    let paneID = PaneID(rawValue: "\(tabID.rawValue):p\(p + 1)")
                    panes.append(PaneRecord(
                        paneID: paneID, workspaceID: workspaceID, tabID: tabID,
                        focused: paneID.rawValue == focusedPane, agentStatus: pane.status, revision: 0,
                        terminalTitleStripped: pane.title, label: nil, cwd: pane.cwd, scroll: nil
                    ))
                }
            }
        }
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil,
            focusedPaneID: focusedPane.map(PaneID.init(rawValue:)),
            workspaces: workspaces, tabs: tabs, panes: panes, layouts: []
        ))
    }

    /// One workspace, one tab, one pane per status given.
    static func single(_ statuses: [AgentStatus], label: String = "acme") -> SessionModel {
        model([Workspace(label: label, tabs: [Tab(label: "main", panes: statuses.map { Pane(status: $0) })])])
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class PaneStatusHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let pane = PaneID(rawValue: "w1:t1:p1")

    func testAPaneFirstSeenIsRecordedAsEnteringItsStatusThen() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        XCTAssertEqual(history.lastChange(of: pane), t0)
        XCTAssertEqual(history.age(of: pane, at: t0.addingTimeInterval(90)), 90)
    }

    func testAnUnchangedStatusAddsNothing() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.working]), at: t0.addingTimeInterval(60))
        XCTAssertEqual(history.lastChange(of: pane), t0)
    }

    func testAChangeIsRecordedAtItsTime() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.blocked]), at: t0.addingTimeInterval(300))
        XCTAssertEqual(history.lastChange(of: pane), t0.addingTimeInterval(300))
    }

    func testAPaneHerdrNoLongerReportsIsForgotten() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([]), at: t0.addingTimeInterval(1))
        XCTAssertNil(history.lastChange(of: pane))
    }

    func testTrimmingKeepsTheTransitionInForceAtTheWindowStart() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.idle]), at: t0)
        history.observe(MissionFixture.single([.working]), at: t0.addingTimeInterval(10))
        let later = t0.addingTimeInterval(2 * 3600)
        history.observe(MissionFixture.single([.working]), at: later)
        XCTAssertEqual(history.lastChange(of: pane), t0.addingTimeInterval(10))
        XCTAssertEqual(history.segments(of: pane, at: later).map(\.status), [.working])
    }

    func testSegmentsCoverTheLastHourWithTheUnrecordedStartLeftEmpty() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.blocked]), at: t0.addingTimeInterval(15 * 60))
        let now = t0.addingTimeInterval(20 * 60)
        let segments = history.segments(of: pane, at: now)
        XCTAssertEqual(segments.map(\.status), [nil, .working, .blocked])
        XCTAssertEqual(segments.map { $0.end.timeIntervalSince($0.start) }, [40 * 60, 15 * 60, 5 * 60])
    }

    func testAPaneNeverSeenIsOneEmptySegment() {
        let history = PaneStatusHistory()
        XCTAssertEqual(history.segments(of: pane, at: t0).map(\.status), [nil])
    }
}
```

- [ ] **Step 3: Run to see it fail**

Run: `xcodegen && CORE PaneStatusHistoryTests`
Expected: build failure, `cannot find 'PaneStatusHistory' in scope`.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Each pane's agent status over the last hour, as flock saw it change. Kept
/// in memory only: after a launch every pane starts with one entry, its
/// status at the first snapshot.
public struct PaneStatusHistory: Equatable, Sendable {
    public struct Transition: Equatable, Sendable {
        public let status: AgentStatus
        public let at: Date
    }

    /// A nil `status` is time before flock first saw the pane.
    public struct Segment: Equatable, Sendable {
        public let status: AgentStatus?
        public let start: Date
        public let end: Date
    }

    public static let window: TimeInterval = 60 * 60

    public private(set) var transitions: [PaneID: [Transition]] = [:]

    public init() {}

    public mutating func observe(_ model: SessionModel, at now: Date) {
        for (paneID, pane) in model.panes where transitions[paneID]?.last?.status != pane.agentStatus {
            transitions[paneID, default: []].append(Transition(status: pane.agentStatus, at: now))
        }
        for paneID in Array(transitions.keys) where model.panes[paneID] == nil {
            transitions[paneID] = nil
        }
        trim(at: now)
    }

    /// Keeps the transition in force at the window's start, so a pane quiet
    /// for hours still knows when it last changed.
    private mutating func trim(at now: Date) {
        let start = now.addingTimeInterval(-Self.window)
        for (paneID, list) in transitions {
            guard let inForce = list.lastIndex(where: { $0.at <= start }), inForce > 0 else { continue }
            transitions[paneID] = Array(list[inForce...])
        }
    }

    public func lastChange(of pane: PaneID) -> Date? {
        transitions[pane]?.last?.at
    }

    public func age(of pane: PaneID, at now: Date) -> TimeInterval? {
        lastChange(of: pane).map { now.timeIntervalSince($0) }
    }

    public func segments(of pane: PaneID, at now: Date) -> [Segment] {
        let start = now.addingTimeInterval(-Self.window)
        guard let list = transitions[pane], let first = list.first else {
            return [Segment(status: nil, start: start, end: now)]
        }
        var result: [Segment] = []
        if first.at > start {
            result.append(Segment(status: nil, start: start, end: first.at))
        }
        for (index, transition) in list.enumerated() {
            let end = index + 1 < list.count ? list[index + 1].at : now
            let from = max(transition.at, start)
            guard end > from else { continue }
            result.append(Segment(status: transition.status, start: from, end: end))
        }
        return result
    }
}
```

- [ ] **Step 5: Run to see it pass**

Run: `CORE PaneStatusHistoryTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/FlockCore/Mission/PaneStatusHistory.swift Tests/FlockCoreTests/MissionFixture.swift Tests/FlockCoreTests/PaneStatusHistoryTests.swift
Scripts/checks.sh && git commit -m "add FlockCore PaneStatusHistory: each pane's status over the last hour"
```

### Task 2: DormantCutoff and its store

**Files:**
- Create: `Sources/FlockCore/Mission/DormantCutoff.swift`
- Test: `Tests/FlockCoreTests/DormantCutoffTests.swift`

**Interfaces:**
- Produces: `enum DormantCutoff: Int, CaseIterable, Sendable { case fifteen = 15, thirty = 30, sixty = 60, twoHours = 120 }` with `displayName: String`, `seconds: TimeInterval`. `@MainActor @Observable final class DormantCutoffStore` with `static let defaultsKey = "flock.dormantCutoff"`, `active: DormantCutoff` (default `.thirty`), `init(userDefaults:)`, `select(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class DormantCutoffTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "DormantCutoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testThirtyMinutesUntilChosenOtherwise() {
        XCTAssertEqual(DormantCutoffStore(userDefaults: defaults()).active, .thirty)
    }

    func testAChoiceSurvivesANewStore() {
        let defaults = defaults()
        DormantCutoffStore(userDefaults: defaults).select(.twoHours)
        XCTAssertEqual(DormantCutoffStore(userDefaults: defaults).active, .twoHours)
    }

    func testChoicesInMinutes() {
        XCTAssertEqual(DormantCutoff.allCases.map(\.rawValue), [15, 30, 60, 120])
        XCTAssertEqual(DormantCutoff.sixty.seconds, 3600)
        XCTAssertEqual(DormantCutoff.twoHours.displayName, "2 hours")
        XCTAssertEqual(DormantCutoff.fifteen.displayName, "15 minutes")
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE DormantCutoffTests`
Expected: build failure, `cannot find 'DormantCutoffStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// How long a pane can go without a status change before mission control
/// folds it away, from Settings.
public enum DormantCutoff: Int, CaseIterable, Sendable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case twoHours = 120

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    public var displayName: String {
        switch self {
        case .fifteen, .thirty: "\(rawValue) minutes"
        case .sixty: "1 hour"
        case .twoHours: "2 hours"
        }
    }
}

/// The Settings choice, persisted like `NotificationLifetimeStore`.
@MainActor
@Observable
public final class DormantCutoffStore {
    public static let defaultsKey = "flock.dormantCutoff"

    public private(set) var active: DormantCutoff

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = DormantCutoff(rawValue: userDefaults.integer(forKey: Self.defaultsKey)) ?? .thirty
    }

    public func select(_ value: DormantCutoff) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE DormantCutoffTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Mission/DormantCutoff.swift Tests/FlockCoreTests/DormantCutoffTests.swift
Scripts/checks.sh && git commit -m "add FlockCore DormantCutoff: when mission control folds a pane away"
```

### Task 3: MissionBoard

**Files:**
- Create: `Sources/FlockCore/Mission/MissionBoard.swift`
- Test: `Tests/FlockCoreTests/MissionBoardTests.swift`

**Interfaces:**
- Consumes: `PaneStatusHistory` (Task 1), `RailSections`, `AttentionToastStack`, `TabTitle.resolve(_:in:)`, `PaneRecord.displayTitle`.
- Produces:
  - `struct MissionCard: Equatable, Sendable, Identifiable` with `paneID`, `workspaceID`, `tabID`, `workspaceName: String`, `tabTitle: String`, `title: String`, `status: AgentStatus`, `since: Date?`, `folder: String`, `id: PaneID`.
  - `struct MissionGroup: Equatable, Sendable, Identifiable` with `workspaceID`, `name`, `cards: [MissionCard]`.
  - `struct MissionBoard: Equatable, Sendable` with `needsYou: [MissionCard]`, `working: [MissionGroup]`, `coolingDown: [MissionCard]`, `dormant: [MissionCard]`, `dormantWorkspaces: Set<WorkspaceID>`, `columns: [[PaneID]]`, and `init(model:sections:toasts:history:cutoff:now:)`.
  - `enum MissionSelection { enum Direction { up, down, left, right }; static func move(_ selection: PaneID?, _ direction: Direction, in columns: [[PaneID]]) -> PaneID? }`.
  - `enum MissionAge { static func text(_ seconds: TimeInterval) -> String }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class MissionBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private typealias W = MissionFixture.Workspace
    private typealias T = MissionFixture.Tab
    private typealias P = MissionFixture.Pane

    private func board(
        _ model: SessionModel, toasts: AttentionToastStack = AttentionToastStack(),
        changedAgo: [String: TimeInterval] = [:], board names: BoardWorkspaceNames? = nil
    ) -> MissionBoard {
        var history = PaneStatusHistory()
        // Every pane first seen two hours ago, then any listed pane changed
        // to its current status `changedAgo` seconds before now.
        var quiet = model
        for id in changedAgo.keys { quiet.panes[PaneID(rawValue: id)]?.agentStatus = .unknown }
        history.observe(quiet, at: now.addingTimeInterval(-7200))
        for (id, ago) in changedAgo.sorted(by: { $0.value > $1.value }) {
            var step = quiet
            step.panes[PaneID(rawValue: id)]?.agentStatus = model.panes[PaneID(rawValue: id)]!.agentStatus
            quiet = step
            history.observe(step, at: now.addingTimeInterval(-ago))
        }
        return MissionBoard(
            model: model, sections: RailSections(model: model, board: names), toasts: toasts,
            history: history, cutoff: 30 * 60, now: now
        )
    }

    private func toast(_ pane: String, _ kind: AttentionToast.Kind, raised: TimeInterval) -> AttentionToast {
        let parts = pane.split(separator: ":")
        return AttentionToast(
            paneID: PaneID(rawValue: pane), tabID: TabID(rawValue: "\(parts[0]):\(parts[1])"),
            workspaceID: WorkspaceID(rawValue: String(parts[0])), kind: kind, subject: "s", breadcrumb: "b",
            raisedAt: now.addingTimeInterval(-raised)
        )
    }

    func testAToastedPaneIsInNeedsYouOldestFirst() {
        let model = MissionFixture.single([.blocked, .done, .working])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        toasts.raise(toast("w1:t1:p2", .finished, raised: 60))
        let b = board(model, toasts: toasts)
        XCTAssertEqual(b.needsYou.map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p2"])
        XCTAssertEqual(b.needsYou.first?.since, now.addingTimeInterval(-600))
        XCTAssertEqual(b.working.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p3"])
    }

    func testABlockedPaneWhoseCardWasClearedCoolsDownInstead() {
        let b = board(MissionFixture.single([.blocked]), changedAgo: ["w1:t1:p1": 120])
        XCTAssertTrue(b.needsYou.isEmpty)
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p1"])
    }

    func testThePaneAtTheCutoffStillCoolsAndOnePastItIsDormant() {
        let b = board(MissionFixture.single([.idle, .idle]), changedAgo: ["w1:t1:p1": 30 * 60, "w1:t1:p2": 30 * 60 + 1])
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p1"])
        XCTAssertEqual(b.dormant.map(\.paneID.rawValue), ["w1:t1:p2"])
    }

    func testAWorkingPaneIsNeverDormantHoweverLongItWorks() {
        let b = board(MissionFixture.single([.working]))
        XCTAssertEqual(b.working.flatMap(\.cards).count, 1)
        XCTAssertTrue(b.dormant.isEmpty)
    }

    func testCoolingDownIsMostRecentChangeFirst() {
        let b = board(MissionFixture.single([.idle, .done]), changedAgo: ["w1:t1:p1": 600, "w1:t1:p2": 60])
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p2", "w1:t1:p1"])
    }

    func testWorkingFollowsRailOrderAndGroupsByWorkspace() {
        let names = BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors")
        let model = MissionFixture.model([
            W(label: "Responses", tabs: [T(label: "r", panes: [P(status: .working)])]),
            W(label: "repo-tools", tabs: [T(label: "a", panes: [P(status: .working)]), T(label: "b", panes: [P(status: .working)])]),
            W(label: "herd: auth-sweep", tabs: [T(label: "worker 1", panes: [P(status: .working)])]),
            W(label: "flock", tabs: [T(label: "c", panes: [P(status: .working)])]),
        ])
        let b = board(model, board: names)
        XCTAssertEqual(b.working.map(\.name), ["repo-tools", "flock", "Responses", "auth-sweep · herd 0/1"])
        XCTAssertEqual(b.working[0].cards.map(\.tabTitle), ["a", "b"])
    }

    func testAWorkspaceIsDormantOnlyWhenEveryPaneIs() {
        let model = MissionFixture.model([
            W(label: "quiet", tabs: [T(label: "a", panes: [P(status: .unknown), P(status: .idle)])]),
            W(label: "busy", tabs: [T(label: "b", panes: [P(status: .idle), P(status: .working)])]),
        ])
        let b = board(model)
        XCTAssertEqual(b.dormantWorkspaces, [WorkspaceID(rawValue: "w1")])
    }

    func testCardsCarryTitleFolderAndTab() {
        let model = MissionFixture.model([W(label: "acme", tabs: [T(label: "api", panes: [P(status: .working, title: "Fix refunds", cwd: "/tmp/acme")])])])
        let card = board(model).working[0].cards[0]
        XCTAssertEqual(card.title, "Fix refunds")
        XCTAssertEqual(card.folder, "/tmp/acme")
        XCTAssertEqual(card.tabTitle, "api")
        XCTAssertEqual(card.workspaceName, "acme")
    }

    func testColumnsAreTheThreeDrawnLanesInOrder() {
        let model = MissionFixture.single([.blocked, .working, .idle])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 10))
        let b = board(model, toasts: toasts, changedAgo: ["w1:t1:p3": 60])
        XCTAssertEqual(b.columns.map { $0.map(\.rawValue) }, [["w1:t1:p1"], ["w1:t1:p2"], ["w1:t1:p3"]])
    }

    func testSelectionMovesWithinAndAcrossLanesSkippingEmptyOnes() {
        let a = PaneID(rawValue: "a"), b = PaneID(rawValue: "b"), c = PaneID(rawValue: "c"), d = PaneID(rawValue: "d")
        let columns = [[a, b], [], [c, d]]
        XCTAssertEqual(MissionSelection.move(a, .down, in: columns), b)
        XCTAssertEqual(MissionSelection.move(b, .down, in: columns), b)
        XCTAssertEqual(MissionSelection.move(b, .right, in: columns), d)
        XCTAssertEqual(MissionSelection.move(c, .left, in: columns), a)
        XCTAssertEqual(MissionSelection.move(nil, .down, in: columns), a)
        XCTAssertNil(MissionSelection.move(nil, .down, in: [[], [], []]))
    }

    func testAgeText() {
        XCTAssertEqual(MissionAge.text(20), "<1m")
        XCTAssertEqual(MissionAge.text(18 * 60), "18m")
        XCTAssertEqual(MissionAge.text(64 * 60), "1h 4m")
        XCTAssertEqual(MissionAge.text(3 * 3600), "3h")
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE MissionBoardTests`
Expected: build failure, `cannot find 'MissionBoard' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One pane as mission control draws it.
public struct MissionCard: Equatable, Sendable, Identifiable {
    public var id: PaneID { paneID }
    public let paneID: PaneID
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    /// A herd's workspace reads "auth-sweep · herd 2/4".
    public let workspaceName: String
    public let tabTitle: String
    public let title: String
    public let status: AgentStatus
    /// When the pane entered `status`, or when its attention card was raised.
    public let since: Date?
    public let folder: String
}

public struct MissionGroup: Equatable, Sendable, Identifiable {
    public var id: WorkspaceID { workspaceID }
    public let workspaceID: WorkspaceID
    public let name: String
    public let cards: [MissionCard]
}

/// Every pane in the lane its state puts it in. Needs you is the attention
/// stack itself, so the dock and the lane can never disagree.
public struct MissionBoard: Equatable, Sendable {
    public let needsYou: [MissionCard]
    public let working: [MissionGroup]
    public let coolingDown: [MissionCard]
    public let dormant: [MissionCard]
    public let dormantWorkspaces: Set<WorkspaceID>

    /// The drawn lanes, top to bottom, for the keyboard.
    public var columns: [[PaneID]] {
        [needsYou.map(\.paneID), working.flatMap(\.cards).map(\.paneID), coolingDown.map(\.paneID)]
    }

    public init(
        model: SessionModel, sections: RailSections, toasts: AttentionToastStack,
        history: PaneStatusHistory, cutoff: TimeInterval, now: Date
    ) {
        let railOrder = sections.workspaces.map(\.workspaceID) + sections.board.map(\.workspaceID)
            + sections.herds.map(\.workspaceID)
        let rank = Dictionary(railOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [WorkspaceID: String] = Dictionary(model.workspaces.map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        for herd in sections.herds {
            names[herd.workspaceID] = "\(herd.name) · herd \(herd.done)/\(herd.total)"
        }

        func card(_ pane: PaneRecord, status: AgentStatus, since: Date?) -> MissionCard {
            let tab = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }
            return MissionCard(
                paneID: pane.paneID, workspaceID: pane.workspaceID, tabID: pane.tabID,
                workspaceName: names[pane.workspaceID] ?? pane.workspaceID.rawValue,
                tabTitle: tab.map { TabTitle.resolve($0, in: model).text } ?? pane.tabID.rawValue,
                title: pane.displayTitle, status: status, since: since,
                folder: pane.foregroundCwd ?? pane.cwd
            )
        }

        func railKey(_ pane: PaneRecord) -> (Int, Int, String) {
            let tabIndex = model.tabs[pane.workspaceID]?.firstIndex { $0.tabID == pane.tabID } ?? Int.max
            return (rank[pane.workspaceID] ?? Int.max, tabIndex, pane.paneID.rawValue)
        }

        let toasted = Set(toasts.toasts.map(\.paneID))
        needsYou = toasts.toasts.reversed().compactMap { toast in
            model.panes[toast.paneID].map { card($0, status: toast.status, since: toast.raisedAt) }
        }

        var working: [PaneRecord] = []
        var cooling: [(PaneRecord, Date?)] = []
        var dormant: [PaneRecord] = []
        for pane in model.panes.values where !toasted.contains(pane.paneID) {
            if pane.agentStatus == .working {
                working.append(pane)
            } else if let age = history.age(of: pane.paneID, at: now), age <= cutoff {
                cooling.append((pane, history.lastChange(of: pane.paneID)))
            } else {
                dormant.append(pane)
            }
        }

        var groups: [MissionGroup] = []
        for pane in working.sorted(by: { railKey($0) < railKey($1) }) {
            let next = card(pane, status: .working, since: history.lastChange(of: pane.paneID))
            if let last = groups.last, last.workspaceID == pane.workspaceID {
                groups[groups.count - 1] = MissionGroup(workspaceID: last.workspaceID, name: last.name, cards: last.cards + [next])
            } else {
                groups.append(MissionGroup(workspaceID: pane.workspaceID, name: next.workspaceName, cards: [next]))
            }
        }
        self.working = groups
        coolingDown = cooling
            .sorted { ($0.1 ?? .distantPast, $1.0.paneID.rawValue) > ($1.1 ?? .distantPast, $0.0.paneID.rawValue) }
            .map { card($0.0, status: $0.0.agentStatus, since: $0.1) }
        self.dormant = dormant.sorted { railKey($0) < railKey($1) }
            .map { card($0, status: $0.agentStatus, since: history.lastChange(of: $0.paneID)) }

        let dormantIDs = Set(dormant.map(\.paneID))
        var byWorkspace: [WorkspaceID: [PaneID]] = [:]
        for pane in model.panes.values { byWorkspace[pane.workspaceID, default: []].append(pane.paneID) }
        dormantWorkspaces = Set(byWorkspace.filter { !$0.value.isEmpty && $0.value.allSatisfy(dormantIDs.contains) }.keys)
    }
}

public enum MissionSelection {
    public enum Direction: Sendable { case up, down, left, right }

    /// Up and down stay in a lane; left and right go to the nearest row of the
    /// next lane that has cards. With nothing selected, the first card.
    public static func move(_ selection: PaneID?, _ direction: Direction, in columns: [[PaneID]]) -> PaneID? {
        guard let selection,
              let column = columns.firstIndex(where: { $0.contains(selection) }),
              let row = columns[column].firstIndex(of: selection)
        else { return columns.first { !$0.isEmpty }?.first }
        switch direction {
        case .up: return columns[column][max(0, row - 1)]
        case .down: return columns[column][min(columns[column].count - 1, row + 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var next = column + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return selection
        }
    }
}

public enum MissionAge {
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE MissionBoardTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Mission/MissionBoard.swift Tests/FlockCoreTests/MissionBoardTests.swift
Scripts/checks.sh && git commit -m "add FlockCore MissionBoard: which lane each pane is in, and in what order"
```

### Task 4: RepoBranch

**Files:**
- Create: `Sources/FlockCore/Mission/RepoBranch.swift`
- Test: `Tests/FlockCoreTests/RepoBranchTests.swift`

**Interfaces:**
- Consumes: `MainCheckout.resolve(from:)`.
- Produces: `struct RepoBranch: Equatable, Sendable { repo: String; branch: String?; text: String }`, `enum RepoBranchReader { static func read(folder: String) -> RepoBranch; static func branch(head: String) -> String? }`, `@MainActor final class RepoBranchCache { init(read:); func repoBranch(for folder: String) -> RepoBranch; func invalidate() }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class RepoBranchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testHeadParsing() {
        XCTAssertEqual(RepoBranchReader.branch(head: "ref: refs/heads/mr-badge\n"), "mr-badge")
        XCTAssertEqual(RepoBranchReader.branch(head: "ref: refs/heads/herd/auth-2"), "herd/auth-2")
        XCTAssertEqual(RepoBranchReader.branch(head: "3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39\n"), "3f2a9c1")
        XCTAssertNil(RepoBranchReader.branch(head: "garbage"))
    }

    func testAMainCheckoutNamesItsFolderAndBranch() throws {
        try write("ref: refs/heads/main\n", to: "acme-api/.git/HEAD")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("acme-api/src"), withIntermediateDirectories: true)
        let read = RepoBranchReader.read(folder: root.appendingPathComponent("acme-api/src").path)
        XCTAssertEqual(read, RepoBranch(repo: "acme-api", branch: "main"))
        XCTAssertEqual(read.text, "acme-api @ main")
    }

    func testALinkedWorktreeNamesTheMainCheckoutAndItsOwnBranch() throws {
        try write("ref: refs/heads/main\n", to: "acme-api/.git/HEAD")
        try write("ref: refs/heads/refunds\n", to: "acme-api/.git/worktrees/refunds/HEAD")
        try write("../..\n", to: "acme-api/.git/worktrees/refunds/commondir")
        let tree = root.appendingPathComponent("trees/refunds")
        try write("gitdir: \(root.appendingPathComponent("acme-api/.git/worktrees/refunds").path)\n", to: "trees/refunds/.git")
        XCTAssertEqual(RepoBranchReader.read(folder: tree.path), RepoBranch(repo: "acme-api", branch: "refunds"))
    }

    func testAFolderOutsideAnyRepositoryIsItsOwnNameAlone() throws {
        let plain = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let read = RepoBranchReader.read(folder: plain.path)
        XCTAssertEqual(read, RepoBranch(repo: "notes", branch: nil))
        XCTAssertEqual(read.text, "notes")
    }

    @MainActor
    func testTheCacheReadsAFolderOnceUntilInvalidated() {
        var reads = 0
        let cache = RepoBranchCache { folder in reads += 1; return RepoBranch(repo: folder, branch: nil) }
        _ = cache.repoBranch(for: "/a")
        _ = cache.repoBranch(for: "/a")
        XCTAssertEqual(reads, 1)
        cache.invalidate()
        _ = cache.repoBranch(for: "/a")
        XCTAssertEqual(reads, 2)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE RepoBranchTests`
Expected: build failure, `cannot find 'RepoBranchReader' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct RepoBranch: Equatable, Sendable {
    public let repo: String
    public let branch: String?

    public init(repo: String, branch: String?) {
        self.repo = repo
        self.branch = branch
    }

    public var text: String { branch.map { "\(repo) @ \($0)" } ?? repo }
}

/// A folder's repository and branch from the files git leaves on disk, like
/// `MainCheckout`: it runs on every mission-control refresh, so it may cost a
/// few file reads but never a git process.
public enum RepoBranchReader {
    public static func read(folder: String) -> RepoBranch {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        guard let checkout = MainCheckout.resolve(from: folder) else { return RepoBranch(repo: name, branch: nil) }
        let head = gitDirectory(from: folder).flatMap { try? String(contentsOf: $0.appendingPathComponent("HEAD"), encoding: .utf8) }
        return RepoBranch(repo: URL(fileURLWithPath: checkout).lastPathComponent, branch: head.flatMap(branch(head:)))
    }

    public static func branch(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = "ref: refs/heads/"
        if line.hasPrefix(local) { return String(line.dropFirst(local.count)) }
        if line.hasPrefix("ref: ") { return line.split(separator: "/").last.map(String.init) }
        if line.count == 40, line.allSatisfy(\.isHexDigit) { return String(line.prefix(7)) }
        return nil
    }

    /// The git directory holding this folder's own HEAD: `.git` itself in a
    /// main checkout, the `gitdir` a linked worktree's `.git` file names.
    static func gitDirectory(from folder: String) -> URL? {
        var directory = URL(fileURLWithPath: folder, isDirectory: true).standardized
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
                else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                return raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw, isDirectory: true).standardized
                    : directory.appendingPathComponent(raw, isDirectory: true).standardized
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }
}

/// One read per folder until the view that shows them opens again.
@MainActor
public final class RepoBranchCache {
    private var entries: [String: RepoBranch] = [:]
    private let read: (String) -> RepoBranch

    public init(read: @escaping (String) -> RepoBranch = RepoBranchReader.read(folder:)) {
        self.read = read
    }

    public func repoBranch(for folder: String) -> RepoBranch {
        if let hit = entries[folder] { return hit }
        let value = read(folder)
        entries[folder] = value
        return value
    }

    public func invalidate() {
        entries.removeAll()
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE RepoBranchTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Mission/RepoBranch.swift Tests/FlockCoreTests/RepoBranchTests.swift
Scripts/checks.sh && git commit -m "add FlockCore RepoBranch: a folder's repo and branch from git's files"
```

### Task 5: JumpBack

**Files:**
- Create: `Sources/FlockCore/Mission/JumpBack.swift`
- Test: `Tests/FlockCoreTests/JumpBackTests.swift`

**Interfaces:**
- Produces: `enum JumpPlace: Equatable, Sendable { case missionControl, pane(PaneID) }`, `struct JumpBack: Equatable, Sendable { origin: JumpPlace?; mutating func jumped(from: JumpPlace); func target(livePanes: Set<PaneID>) -> JumpPlace? }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class JumpBackTests: XCTestCase {
    private let a = PaneID(rawValue: "a")
    private let b = PaneID(rawValue: "b")

    func testNothingToGoBackToBeforeAnyJump() {
        XCTAssertNil(JumpBack().target(livePanes: [a]))
    }

    func testAJumpRemembersWhereItLeftFrom() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        XCTAssertEqual(back.target(livePanes: [a, b]), .pane(a))
        back.jumped(from: .missionControl)
        XCTAssertEqual(back.target(livePanes: [a, b]), .missionControl)
    }

    func testGoingBackRecordsWhereItLeftSoTheNextPressGoesForward() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        back.jumped(from: .pane(b))
        XCTAssertEqual(back.target(livePanes: [a, b]), .pane(b))
    }

    func testAClosedOriginPaneOffersNothing() {
        var back = JumpBack()
        back.jumped(from: .pane(a))
        XCTAssertNil(back.target(livePanes: [b]))
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE JumpBackTests`
Expected: build failure, `cannot find 'JumpBack' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum JumpPlace: Equatable, Sendable {
    case missionControl
    case pane(PaneID)
}

/// Where the last jump left from, one level deep. Going back is itself a
/// jump, so pressing it twice returns to where it started.
public struct JumpBack: Equatable, Sendable {
    public private(set) var origin: JumpPlace?

    public init() {}

    public mutating func jumped(from place: JumpPlace) {
        origin = place
    }

    public func target(livePanes: Set<PaneID>) -> JumpPlace? {
        switch origin {
        case .pane(let pane)?: livePanes.contains(pane) ? origin : nil
        case .missionControl?: .missionControl
        case nil: nil
        }
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE JumpBackTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Mission/JumpBack.swift Tests/FlockCoreTests/JumpBackTests.swift
Scripts/checks.sh && git commit -m "add FlockCore JumpBack: where the last jump left from"
```

### Task 6: AllWorkspacesMode and its store

**Files:**
- Create: `Sources/FlockCore/Grid/AllWorkspacesMode.swift`
- Test: `Tests/FlockCoreTests/AllWorkspacesModeTests.swift`

**Interfaces:**
- Produces: `enum AllWorkspacesMode: String, CaseIterable, Sendable { case missionControl, arrange }` with `title`. `@MainActor @Observable final class AllWorkspacesModeStore` with `static let defaultsKey = "flock.allWorkspacesMode"`, `active` (default `.missionControl`), `select(_:)`, and `missionSelection: PaneID?` (not persisted).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class AllWorkspacesModeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AllWorkspacesModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMissionControlUntilChosenOtherwise() {
        XCTAssertEqual(AllWorkspacesModeStore(userDefaults: defaults()).active, .missionControl)
    }

    func testTheLastModeUsedSurvivesANewStore() {
        let defaults = defaults()
        AllWorkspacesModeStore(userDefaults: defaults).select(.arrange)
        XCTAssertEqual(AllWorkspacesModeStore(userDefaults: defaults).active, .arrange)
    }

    func testTitles() {
        XCTAssertEqual(AllWorkspacesMode.allCases.map(\.title), ["Mission control", "Arrange"])
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE AllWorkspacesModeTests`
Expected: build failure, `cannot find 'AllWorkspacesModeStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

public enum AllWorkspacesMode: String, CaseIterable, Sendable {
    case missionControl
    case arrange

    public var title: String {
        switch self {
        case .missionControl: "Mission control"
        case .arrange: "Arrange"
        }
    }
}

/// The All Workspaces view's mode, remembered across launches so ⇧⌘R opens
/// where it was left.
@MainActor
@Observable
public final class AllWorkspacesModeStore {
    public static let defaultsKey = "flock.allWorkspacesMode"

    public private(set) var active: AllWorkspacesMode
    /// The selected mission-control card, kept while the view is closed so
    /// Jump Back reopens on it.
    public var missionSelection: PaneID?

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(AllWorkspacesMode.init(rawValue:)) ?? .missionControl
    }

    public func select(_ mode: AllWorkspacesMode) {
        active = mode
        userDefaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE AllWorkspacesModeTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Grid/AllWorkspacesMode.swift Tests/FlockCoreTests/AllWorkspacesModeTests.swift
Scripts/checks.sh && git commit -m "add FlockCore AllWorkspacesMode: mission control or arrange, remembered"
```

### Task 7: IdentityPalette and WorkspaceIdentityStore

**Files:**
- Create: `Sources/FlockCore/Theme/IdentityPalette.swift`
- Create: `Sources/FlockCore/Theme/WorkspaceIdentityStore.swift`
- Test: `Tests/FlockCoreTests/IdentityPaletteTests.swift`, `Tests/FlockCoreTests/WorkspaceIdentityStoreTests.swift`

**Interfaces:**
- Consumes: `ThemePalette` (`accent`, `yellow`, `red`, `teal`, `green`, `panelBg`, `chromeRoles.canvas`), `ChromeRoles.isLight(panelBg:)`, `RGB.contrastRatio(with:)`, `RailSections`.
- Produces: `enum IdentityPalette { static let count = 8; static let statusClearance = 25.0; static let minimumContrast = 3.0; static func colors(for: ThemePalette) -> [RGB]; static func hue(of: RGB) -> Double; static func distance(_:_:) -> Double }`. `@MainActor @Observable final class WorkspaceIdentityStore` with `static let defaultsKey = "flock.workspaceIdentity"`, `static let boardKey = "section:board"`, `static func key(for: WorkspaceID, sections: RailSections) -> String?` (nil for a herd), `index(for key: String) -> Int?`, `assign(_ keys: [String])`, `setOverride(_ index: Int?, for key: String)`, `keepOnly(_ keys: Set<String>)`.

- [ ] **Step 1: Write the failing palette test**

```swift
import XCTest
@testable import FlockCore

final class IdentityPaletteTests: XCTestCase {
    func testEveryBuiltinThemeGetsEightLegibleHuesClearOfEveryStatusHue() {
        for palette in ThemePalette.builtins {
            let colors = IdentityPalette.colors(for: palette)
            XCTAssertEqual(colors.count, IdentityPalette.count, palette.id)
            let statusHues = [palette.yellow, palette.red, palette.teal, palette.green].map(IdentityPalette.hue(of:))
            for color in colors {
                let hue = IdentityPalette.hue(of: color)
                for status in statusHues {
                    // One degree of slack for rounding to whole bytes.
                    XCTAssertGreaterThanOrEqual(IdentityPalette.distance(hue, status), IdentityPalette.statusClearance - 1, "\(palette.id) \(color)")
                }
                XCTAssertGreaterThanOrEqual(color.contrastRatio(with: palette.chromeRoles.canvas), IdentityPalette.minimumContrast, "\(palette.id) \(color)")
            }
        }
    }

    func testHueDistanceWrapsAroundTheWheel() {
        XCTAssertEqual(IdentityPalette.distance(350, 10), 20)
        XCTAssertEqual(IdentityPalette.distance(10, 350), 20)
    }
}
```

- [ ] **Step 2: Write the failing store test**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class WorkspaceIdentityStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WorkspaceIdentityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNewWorkspacesTakeTheLeastUsedHueInOrder() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1", "w2", "w3"])
        XCTAssertEqual(["w1", "w2", "w3"].compactMap(store.index(for:)), [0, 1, 2])
    }

    func testAnAssignmentNeverChangesOnceMade() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w2"])
        store.assign(["w1", "w2"])
        XCTAssertEqual(store.index(for: "w2"), 0)
        XCTAssertEqual(store.index(for: "w1"), 1)
    }

    func testAnOverrideWinsAndSurvivesANewStore() {
        let defaults = defaults()
        let store = WorkspaceIdentityStore(userDefaults: defaults)
        store.assign(["w1"])
        store.setOverride(5, for: "w1")
        XCTAssertEqual(WorkspaceIdentityStore(userDefaults: defaults).index(for: "w1"), 5)
        store.setOverride(nil, for: "w1")
        XCTAssertEqual(store.index(for: "w1"), 0)
    }

    func testWorkspacesNoLongerReportedAreDroppedButTheBoardKeyStays() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign([WorkspaceIdentityStore.boardKey, "w1", "w2"])
        store.keepOnly(["w2"])
        XCTAssertNil(store.index(for: "w1"))
        XCTAssertNotNil(store.index(for: "w2"))
        XCTAssertNotNil(store.index(for: WorkspaceIdentityStore.boardKey))
    }

    func testKeysShareTheBoardsAndGiveHerdsNone() {
        let model = MissionFixture.model([
            .init(label: "acme", tabs: [.init(label: "a", panes: [.init(status: .idle)])]),
            .init(label: "Responses", tabs: [.init(label: "r", panes: [.init(status: .idle)])]),
            .init(label: "herd: sweep", tabs: [.init(label: "w", panes: [.init(status: .idle)])]),
        ])
        let sections = RailSections(model: model, board: BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors"))
        XCTAssertEqual(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w1"), sections: sections), "w1")
        XCTAssertEqual(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w2"), sections: sections), WorkspaceIdentityStore.boardKey)
        XCTAssertNil(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w3"), sections: sections))
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `xcodegen && CORE IdentityPaletteTests && CORE WorkspaceIdentityStoreTests`
Expected: build failure, `cannot find 'IdentityPalette' in scope`.

- [ ] **Step 4: Implement the palette**

```swift
import Foundation

/// Eight hues that tell workspaces apart, derived per theme. None sits within
/// `statusClearance` degrees of a status hue, because colour in flock already
/// means agent status, and each clears `minimumContrast` on the canvas so the
/// identity square reads as a mark.
public enum IdentityPalette {
    public static let count = 8
    public static let statusClearance = 25.0
    public static let minimumContrast = 3.0

    public static func colors(for palette: ThemePalette) -> [RGB] {
        let statusHues = [palette.yellow, palette.red, palette.teal, palette.green].map(hue(of:))
        let allowed = stride(from: 0.0, to: 360.0, by: 5.0).filter { candidate in
            statusHues.allSatisfy { distance(candidate, $0) >= statusClearance }
        }
        let accent = HSL(palette.accent)
        let darkens = ChromeRoles.isLight(panelBg: palette.panelBg)
        return spread(allowed).map { hue in
            legible(
                HSL(hue: hue, saturation: max(accent.saturation, 0.55), lightness: accent.lightness),
                on: palette.chromeRoles.canvas, darkening: darkens
            )
        }
    }

    public static func hue(of rgb: RGB) -> Double { HSL(rgb).hue }

    public static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Evenly spaced through the allowed hues, so neighbours differ as much
    /// as the gaps between status hues allow.
    private static func spread(_ hues: [Double]) -> [Double] {
        guard hues.count > count else { return hues }
        return (0..<count).map { hues[$0 * hues.count / count] }
    }

    private static func legible(_ start: HSL, on ground: RGB, darkening: Bool) -> RGB {
        var color = start
        for _ in 0..<50 {
            let rgb = color.rgb
            if rgb.contrastRatio(with: ground) >= minimumContrast { return rgb }
            color.lightness = min(1, max(0, color.lightness + (darkening ? -0.02 : 0.02)))
        }
        return color.rgb
    }
}

struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init(_ rgb: RGB) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        lightness = (high + low) / 2
        saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var h: Double
        if delta == 0 { h = 0 }
        else if high == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { h = 60 * ((b - r) / delta + 2) }
        else { h = 60 * ((r - g) / delta + 4) }
        if h < 0 { h += 360 }
        hue = h
    }

    var rgb: RGB {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        func byte(_ v: Double) -> Int { Int(((v + m) * 255).rounded()).clamped(0, 255) }
        return RGB(byte(r), byte(g), byte(b))
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(high, Swift.max(low, self)) }
}
```

- [ ] **Step 5: Implement the store**

```swift
import Foundation
import Observation

/// Which identity hue (an index into `IdentityPalette.colors`) each
/// workspace wears. Keyed by workspace id so a rename keeps the colour.
/// Board's workspaces share one key; herds have none and draw neutral.
@MainActor
@Observable
public final class WorkspaceIdentityStore {
    public static let defaultsKey = "flock.workspaceIdentity"
    public static let boardKey = "section:board"

    public private(set) var assigned: [String: Int]
    public private(set) var overrides: [String: Int]

    @ObservationIgnored private let userDefaults: UserDefaults

    private struct Stored: Codable {
        var assigned: [String: Int]
        var overrides: [String: Int]
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        assigned = stored?.assigned ?? [:]
        overrides = stored?.overrides ?? [:]
    }

    public static func key(for workspace: WorkspaceID, sections: RailSections) -> String? {
        if sections.herds.contains(where: { $0.workspaceID == workspace }) { return nil }
        if sections.board.contains(where: { $0.workspaceID == workspace }) { return boardKey }
        return workspace.rawValue
    }

    public func index(for key: String) -> Int? {
        overrides[key] ?? assigned[key]
    }

    /// Gives each key without a hue the least used one, lowest index first.
    public func assign(_ keys: [String]) {
        var next = assigned
        for key in keys where next[key] == nil {
            var uses = Array(repeating: 0, count: IdentityPalette.count)
            for index in next.values where uses.indices.contains(index) { uses[index] += 1 }
            next[key] = uses.indices.min { (uses[$0], $0) < (uses[$1], $1) } ?? 0
        }
        guard next != assigned else { return }
        assigned = next
        save()
    }

    public func setOverride(_ index: Int?, for key: String) {
        overrides[key] = index
        save()
    }

    public func keepOnly(_ keys: Set<String>) {
        let keep = keys.union([Self.boardKey])
        let nextAssigned = assigned.filter { keep.contains($0.key) }
        let nextOverrides = overrides.filter { keep.contains($0.key) }
        guard nextAssigned != assigned || nextOverrides != overrides else { return }
        assigned = nextAssigned
        overrides = nextOverrides
        save()
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(assigned: assigned, overrides: overrides))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 6: Run to see them pass**

Run: `CORE IdentityPaletteTests && CORE WorkspaceIdentityStoreTests`
Expected: `** TEST SUCCEEDED **` twice. If a builtin theme fails the clearance or contrast assertion, fix the algorithm (for example widen `saturation` or step `legible` further); never relax the test constants, which are the spec's.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlockCore/Theme/IdentityPalette.swift Sources/FlockCore/Theme/WorkspaceIdentityStore.swift Tests/FlockCoreTests/IdentityPaletteTests.swift Tests/FlockCoreTests/WorkspaceIdentityStoreTests.swift
Scripts/checks.sh && git commit -m "add FlockCore identity colours: eight hues per theme clear of status, and who wears which"
```

### Task 8: IslandLayout

**Files:**
- Create: `Sources/FlockCore/Grid/IslandLayout.swift`
- Test: `Tests/FlockCoreTests/IslandLayoutTests.swift`

**Interfaces:**
- Produces: `enum IslandLayout` with `struct Metrics` (fields below, `init()` gives the spec's values), `struct Island { id: WorkspaceID; tabs: Int }`, `struct Fit: Equatable { thumbnailWidth; thumbnailHeight; rows: [[WorkspaceID]]; tabsPerRow: [WorkspaceID: Int]; scrolls: Bool }`, `static func width(tabs:perRow:thumbnail:metrics:) -> CGFloat`, `static func fit(_ islands: [Island], in size: CGSize, hasDormantStrip: Bool, metrics: Metrics = Metrics()) -> Fit`. `struct IslandFitHold { mutating func update(_ islands:, in size:, hasDormantStrip:, dragging: Bool, metrics: = Metrics()) -> Fit }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class IslandLayoutTests: XCTestCase {
    private func islands(_ tabs: [Int]) -> [IslandLayout.Island] {
        tabs.enumerated().map { IslandLayout.Island(id: WorkspaceID(rawValue: "w\($0.offset + 1)"), tabs: $0.element) }
    }

    func testAFewSmallWorkspacesGetTheCap() {
        let fit = IslandLayout.fit(islands([1, 2]), in: CGSize(width: 1700, height: 1000), hasDormantStrip: false)
        XCTAssertEqual(fit.thumbnailWidth, 320)
        XCTAssertFalse(fit.scrolls)
    }

    func testTheLargestWidthThatFitsIsChosen() {
        let metrics = IslandLayout.Metrics()
        let size = CGSize(width: 1750, height: 980)
        let fit = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size, hasDormantStrip: true)
        XCTAssertFalse(fit.scrolls)
        XCTAssertLessThan(fit.thumbnailWidth, 320)
        let bigger = IslandLayout.fit(islands([3, 2, 1, 1, 3, 5, 1, 1, 2, 1, 1, 1]), in: size, hasDormantStrip: true, metrics: {
            var m = metrics; m.minimumWidth = fit.thumbnailWidth + metrics.step; return m
        }())
        XCTAssertTrue(bigger.scrolls, "one step larger no longer fits")
    }

    func testTooManyWorkspacesScrollAtTheFloor() {
        let fit = IslandLayout.fit(islands(Array(repeating: 4, count: 40)), in: CGSize(width: 900, height: 600), hasDormantStrip: false)
        XCTAssertEqual(fit.thumbnailWidth, 120)
        XCTAssertTrue(fit.scrolls)
    }

    func testIslandsPackLeftToRightInOrderAndWrap() {
        let fit = IslandLayout.fit(islands([3, 3, 3]), in: CGSize(width: 1300, height: 400), hasDormantStrip: false)
        XCTAssertEqual(fit.rows.flatMap { $0 }.map(\.rawValue), ["w1", "w2", "w3"])
        XCTAssertGreaterThan(fit.rows.count, 1)
    }

    func testAnIslandWiderThanTheWindowWrapsItsTabs() {
        let fit = IslandLayout.fit(islands([12]), in: CGSize(width: 900, height: 2000), hasDormantStrip: false)
        let perRow = try! XCTUnwrap(fit.tabsPerRow[WorkspaceID(rawValue: "w1")])
        XCTAssertLessThan(perRow, 12)
        XCTAssertLessThanOrEqual(IslandLayout.width(tabs: 12, perRow: perRow, thumbnail: fit.thumbnailWidth, metrics: .init()), 900)
    }

    func testTheFitHoldsStillWhileADragIsLive() {
        var hold = IslandFitHold()
        let first = hold.update(islands([2]), in: CGSize(width: 1700, height: 1000), hasDormantStrip: false, dragging: false)
        let during = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), hasDormantStrip: false, dragging: true)
        XCTAssertEqual(first, during)
        let after = hold.update(islands([2, 6, 6, 6]), in: CGSize(width: 900, height: 500), hasDormantStrip: false, dragging: false)
        XCTAssertNotEqual(first, after)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE IslandLayoutTests`
Expected: build failure, `cannot find 'IslandLayout' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// Arrange's layout: islands packed left to right in rail order, every
/// thumbnail one size, the largest size at which the whole view fits.
public enum IslandLayout {
    public struct Metrics: Equatable, Sendable {
        /// Between islands, across a row and down the view.
        public var islandGap: CGFloat = 28
        public var tabGap: CGFloat = 8
        public var horizontalPadding: CGFloat = 16
        /// Top padding, the header row and the gap under it.
        public var headerHeight: CGFloat = 46
        public var bottomPadding: CGFloat = 16
        public var aspect: CGFloat = 0.72
        public var minimumWidth: CGFloat = 120
        public var maximumWidth: CGFloat = 320
        public var step: CGFloat = 2
        /// The dormant strip and the gap above it.
        public var dormantStripHeight: CGFloat = 44

        public init() {}
    }

    public struct Island: Equatable, Sendable {
        public let id: WorkspaceID
        public let tabs: Int

        public init(id: WorkspaceID, tabs: Int) {
            self.id = id
            self.tabs = tabs
        }
    }

    public struct Fit: Equatable, Sendable {
        public let thumbnailWidth: CGFloat
        public let thumbnailHeight: CGFloat
        public let rows: [[WorkspaceID]]
        public let tabsPerRow: [WorkspaceID: Int]
        public let scrolls: Bool
    }

    public static func thumbnailHeight(_ width: CGFloat, metrics: Metrics) -> CGFloat {
        (width * metrics.aspect).rounded()
    }

    public static func width(tabs: Int, perRow: Int, thumbnail: CGFloat, metrics: Metrics) -> CGFloat {
        let across = CGFloat(max(1, min(tabs, perRow)))
        return 2 * metrics.horizontalPadding + across * thumbnail + (across - 1) * metrics.tabGap
    }

    static func height(tabs: Int, perRow: Int, thumbnail: CGFloat, metrics: Metrics) -> CGFloat {
        let rows = CGFloat((max(1, tabs) + perRow - 1) / perRow)
        return metrics.headerHeight + rows * thumbnailHeight(thumbnail, metrics: metrics)
            + (rows - 1) * metrics.tabGap + metrics.bottomPadding
    }

    static func layout(_ islands: [Island], thumbnail: CGFloat, in width: CGFloat, metrics: Metrics)
        -> (rows: [[WorkspaceID]], perRow: [WorkspaceID: Int], height: CGFloat)
    {
        let maxAcross = max(1, Int((width - 2 * metrics.horizontalPadding + metrics.tabGap) / (thumbnail + metrics.tabGap)))
        var rows: [[WorkspaceID]] = []
        var perRow: [WorkspaceID: Int] = [:]
        var rowHeights: [CGFloat] = []
        var x: CGFloat = 0
        for island in islands {
            let across = min(max(1, island.tabs), maxAcross)
            perRow[island.id] = across
            let w = self.width(tabs: island.tabs, perRow: across, thumbnail: thumbnail, metrics: metrics)
            let h = height(tabs: island.tabs, perRow: across, thumbnail: thumbnail, metrics: metrics)
            if rows.isEmpty || x + metrics.islandGap + w > width {
                rows.append([island.id])
                rowHeights.append(h)
                x = w
            } else {
                rows[rows.count - 1].append(island.id)
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], h)
                x += metrics.islandGap + w
            }
        }
        let total = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * metrics.islandGap
        return (rows, perRow, total)
    }

    public static func fit(_ islands: [Island], in size: CGSize, hasDormantStrip: Bool, metrics: Metrics = Metrics()) -> Fit {
        let available = size.height - (hasDormantStrip ? metrics.dormantStripHeight : 0)
        var width = metrics.maximumWidth
        while width >= metrics.minimumWidth {
            let candidate = layout(islands, thumbnail: width, in: size.width, metrics: metrics)
            if candidate.height <= available {
                return Fit(
                    thumbnailWidth: width, thumbnailHeight: thumbnailHeight(width, metrics: metrics),
                    rows: candidate.rows, tabsPerRow: candidate.perRow, scrolls: false
                )
            }
            width -= metrics.step
        }
        let floor = layout(islands, thumbnail: metrics.minimumWidth, in: size.width, metrics: metrics)
        return Fit(
            thumbnailWidth: metrics.minimumWidth, thumbnailHeight: thumbnailHeight(metrics.minimumWidth, metrics: metrics),
            rows: floor.rows, tabsPerRow: floor.perRow, scrolls: true
        )
    }
}

/// The fit Arrange draws with. A drag freezes it: a drop target that moved
/// under the pointer would land the drop somewhere nobody aimed.
public struct IslandFitHold: Equatable, Sendable {
    public private(set) var fit: IslandLayout.Fit?

    public init() {}

    public mutating func update(
        _ islands: [IslandLayout.Island], in size: CGSize, hasDormantStrip: Bool, dragging: Bool,
        metrics: IslandLayout.Metrics = IslandLayout.Metrics()
    ) -> IslandLayout.Fit {
        if dragging, let fit { return fit }
        let next = IslandLayout.fit(islands, in: size, hasDormantStrip: hasDormantStrip, metrics: metrics)
        fit = next
        return next
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `CORE IslandLayoutTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Grid/IslandLayout.swift Tests/FlockCoreTests/IslandLayoutTests.swift
Scripts/checks.sh && git commit -m "add FlockCore IslandLayout: the largest thumbnail at which every island fits"
```

---

## Milestone 2: Mission control

### Task 9: SessionViewModel records history and jumps

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (stored properties near line 43; `update(model:connection:)` at line 212; the jump functions at lines 383-397)
- Modify: `Sources/Flock/Views/AttentionToastStack.swift:115`, `Sources/Flock/FlockApp.swift:535`, `Sources/Flock/Palette/PaletteRunner.swift:77` (call sites, updated in Task 10; for this task pass `from: nil` so they compile)
- Test: `Tests/FlockCoreTests/MissionJumpTests.swift`

**Interfaces:**
- Consumes: `PaneStatusHistory`, `JumpBack`, `JumpPlace`, `RepoBranchCache`.
- Produces on `SessionViewModel`:
  - `public private(set) var statusHistory: PaneStatusHistory`
  - `public private(set) var jumpBack: JumpBack`
  - `public let repoBranches: RepoBranchCache`
  - `public var currentTime: Date` (reads the injected clock)
  - `public func jumpToPane(_ pane: PaneID, from origin: JumpPlace?) async`
  - `public func jumpToAttentionToast(pane: PaneID, from origin: JumpPlace?) async` (gains `from`)
  - `public func jumpToOldestDisplayedAttentionToast(from origin: JumpPlace?) async` (gains `from`)
  - `public func jumpToOldestAttentionToast(from origin: JumpPlace?) async` (new: oldest of all cards)
  - `public var jumpBackTarget: JumpPlace?`
  - `public func recordJump(from origin: JumpPlace?)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

private actor RecordingClient: HerdrCommandClient {
    private(set) var calls: [String] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append(method)
        return Data("{}".utf8)
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
final class MissionJumpTests: XCTestCase {
    private func model(_ statuses: [AgentStatus]) -> SessionModel {
        MissionFixture.model([
            .init(label: "home", tabs: [.init(label: "main", panes: [.init(status: .idle)])]),
            .init(label: "acme", tabs: [.init(label: "api", panes: statuses.map { .init(status: $0) })]),
        ], focusedPane: "w1:t1:p1")
    }

    func testEveryUpdateFeedsTheStatusHistory() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: model([.working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(120)
        viewModel.update(model: model([.blocked]), connection: .live)
        XCTAssertEqual(viewModel.statusHistory.lastChange(of: PaneID(rawValue: "w2:t1:p1")), clock.now)
    }

    func testJumpingToAPaneFocusesItAndRemembersTheOrigin() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: model([.working]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"), from: .missionControl)
        let calls = await client.calls
        XCTAssertEqual(calls, ["tab.focus", "pane.focus"])
        XCTAssertEqual(viewModel.jumpBackTarget, .missionControl)
    }

    func testInMissionControlTheKeyOpensTheOldestCardOfAllNotTheOldestTheDockDraws() async {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.attentionCardLimit = 1
        viewModel.update(model: model([.working, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .blocked]), connection: .live)
        await viewModel.jumpToOldestAttentionToast(from: .missionControl)
        XCTAssertNil(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1")), "the oldest card was taken")
        XCTAssertNotNil(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p2")))
    }

    func testAClosedOriginOffersNoWayBack() async {
        let viewModel = SessionViewModel(client: RecordingClient())
        viewModel.update(model: model([.working, .idle]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"), from: .pane(PaneID(rawValue: "w2:t1:p2")))
        viewModel.update(model: model([.working]), connection: .live)
        XCTAssertNil(viewModel.jumpBackTarget)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `xcodegen && CORE MissionJumpTests`
Expected: build failure, `value of type 'SessionViewModel' has no member 'statusHistory'`.

- [ ] **Step 3: Add the stored state**

After `public private(set) var attentionToasts ...` (line 43-47) add:

```swift
    public private(set) var statusHistory = PaneStatusHistory()
    public private(set) var jumpBack = JumpBack()
    public let repoBranches = RepoBranchCache()
```

and near `public var attentionCardLimit` add:

```swift
    /// The injected clock, so mission control's ages and history agree.
    public var currentTime: Date { now() }
```

- [ ] **Step 4: Feed the history**

In `update(model:connection:)`, directly after `self.model = model`:

```swift
        if let model {
            // Assigned only on a real change: the setter notifies every
            // observer, and most updates change no pane's status.
            var history = statusHistory
            history.observe(model, at: now())
            if history != statusHistory { statusHistory = history }
        }
```

- [ ] **Step 5: Replace the jump functions (lines 383-397)**

```swift
    public func jumpToOldestDisplayedAttentionToast(from origin: JumpPlace?) async {
        guard let toast = attentionToasts.oldestVisible(limit: attentionCardLimit) else { return }
        await jumpToAttentionToast(pane: toast.paneID, from: origin)
    }

    /// Mission control draws every card, so its oldest is the stack's.
    public func jumpToOldestAttentionToast(from origin: JumpPlace?) async {
        guard let toast = attentionToasts.toasts.last else { return }
        await jumpToAttentionToast(pane: toast.paneID, from: origin)
    }

    /// Focuses the tab and pane by explicit id, never the workspace:
    /// `tab.focus` moves herdr's workspace along with it, while a separate
    /// `workspace.focus` lands on that workspace's remembered tab first, and
    /// herdr's echo of it shows the wrong tab before the target arrives.
    public func jumpToAttentionToast(pane: PaneID, from origin: JumpPlace?) async {
        guard let toast = attentionToasts.toast(pane: pane) else { return }
        recordJump(from: origin)
        attentionToasts.dismiss(pane: pane)
        await jumpToHerdr(tab: toast.tabID)
        await jumpToHerdr(pane: toast.paneID)
    }

    public func jumpToPane(_ pane: PaneID, from origin: JumpPlace?) async {
        guard let record = model?.panes[pane] else { return }
        recordJump(from: origin)
        attentionToasts.dismiss(pane: pane)
        await jumpToHerdr(tab: record.tabID)
        await jumpToHerdr(pane: pane)
    }

    public var jumpBackTarget: JumpPlace? {
        jumpBack.target(livePanes: Set(model?.panes.keys ?? [:].keys))
    }

    public func recordJump(from origin: JumpPlace?) {
        guard let origin else { return }
        jumpBack.jumped(from: origin)
    }
```

- [ ] **Step 6: Keep the old call sites compiling**

Change `viewModel.jumpToAttentionToast(pane: toast.paneID)` in `Sources/Flock/Views/AttentionToastStack.swift:115` and the test call in `Tests/FlockCoreTests/AttentionToastTests.swift` to pass `from: nil`; change `jumpToOldestDisplayedAttentionToast()` in `FlockApp.swift:535` and `PaletteRunner.swift:77` to `jumpToOldestDisplayedAttentionToast(from: nil)`. Task 10 replaces these with real origins. Find any others:

```bash
grep -rn "jumpToAttentionToast(pane:\|jumpToOldestDisplayedAttentionToast()" Sources Tests
```

- [ ] **Step 7: Run to see it pass, and the existing attention tests still pass**

Run: `CORE MissionJumpTests && CORE AttentionToastTests`
Expected: `** TEST SUCCEEDED **` twice.

- [ ] **Step 8: Commit**

```bash
git add -A Sources/FlockCore/ViewModels/SessionViewModel.swift Sources/Flock Tests/FlockCoreTests
Scripts/checks.sh && git commit -m "session view model: keep each pane's status history, and remember where a jump left from"
```

### Task 10: Keys, menus, palette and the jump navigator

**Files:**
- Create: `Sources/Flock/Menus/JumpNavigator.swift`
- Modify: `Sources/Flock/Menus/ViewCommand.swift`, `Sources/Flock/FlockApp.swift` (View menu at lines 520-548; store creation near line 142; environment injection where `.environment(` is applied to `MainWindow`), `Sources/Flock/Drag/DragCoordinator+Grid.swift`, `Sources/Flock/Palette/PaletteCatalog.swift`, `Sources/Flock/Palette/PaletteRunner.swift`, `Sources/Flock/Palette/CommandPaletteView.swift:213`, `Sources/Flock/Views/AttentionToastStack.swift:115`
- Test: `Tests/FlockChromeRender/PaletteShortcutTests.swift`, `Tests/FlockChromeRender/PaletteCatalogTests.swift` (existing; extend)

**Interfaces:**
- Consumes: Task 6 store, Task 9 view model API.
- Produces: `ViewCommand.jumpBack` (⇧⌘J, "Jump Back", `flock.view.jumpBack`); Clear Notifications on ⇧⌘U. `DragCoordinator.openGrid()`. `@MainActor struct JumpNavigator { init(viewModel:drag:mode:); var currentPlace: JumpPlace?; func openOldest(); func open(toast pane: PaneID); func open(pane: PaneID); func back() }`. `PaletteContext.canJumpBack: Bool`.

- [ ] **Step 1: Write the failing shortcut test**

Add to `Tests/FlockChromeRender/PaletteShortcutTests.swift` inside its test class:

```swift
    func testTheJKeysGoThereAndBackAndClearMovesToU() {
        XCTAssertEqual(ViewCommand.openOldestNotification.key, "j")
        XCTAssertEqual(ViewCommand.openOldestNotification.modifiers, .command)
        XCTAssertEqual(ViewCommand.jumpBack.key, "j")
        XCTAssertEqual(ViewCommand.jumpBack.modifiers, [.command, .shift])
        XCTAssertEqual(ViewCommand.jumpBack.title, "Jump Back")
        XCTAssertEqual(ViewCommand.clearNotifications.key, "u")
        XCTAssertEqual(ViewCommand.clearNotifications.modifiers, [.command, .shift])
    }
```

And to `Tests/FlockChromeRender/PaletteCatalogTests.swift` (it already has `private func ids(_ context: PaletteContext) -> [String]`):

```swift
    func testJumpBackIsOfferedOnlyWhenThereIsSomewhereToGo() {
        XCTAssertFalse(ids(PaletteContext()).contains("view.jumpback"))
        XCTAssertTrue(ids(PaletteContext(canJumpBack: true)).contains("view.jumpback"))
    }
```

- [ ] **Step 2: Run to see it fail**

Run: `RENDER PaletteShortcutTests`
Expected: build failure, `type 'ViewCommand' has no member 'jumpBack'`.

`PaletteContext` gets its new field as `var canJumpBack = false` beside `hasNotifications`, so the memberwise initializer takes `canJumpBack:` and every existing call keeps compiling.

- [ ] **Step 3: ViewCommand**

```swift
enum ViewCommand: String, CaseIterable {
    case newTab, newWorkspace, closeTab, closeWorkspace
    case rearrangeMode, allWorkspaces, openOldestNotification, jumpBack, clearNotifications, commandPalette
```

with these arms added or changed:

```swift
        case .jumpBack: "Jump Back"                                  // title
        case .openOldestNotification, .jumpBack: "j"                 // key
        case .clearNotifications: "u"                                // key
        case .newWorkspace, .closeTab, .clearNotifications, .jumpBack: [.command, .shift]   // modifiers
        case .jumpBack: "flock.view.jumpBack"                        // accessibilityIdentifier
```

- [ ] **Step 4: DragCoordinator.openGrid**

In `Sources/Flock/Drag/DragCoordinator+Grid.swift` add beside `toggleGrid()`:

```swift
    func openGrid() {
        updateGrid { $0.open() }
    }
```

- [ ] **Step 5: JumpNavigator**

```swift
import FlockCore

/// Where a jump starts and how Jump Back returns, shared by the View menu,
/// the palette, the dock and mission control so every route records the
/// same origin.
@MainActor
struct JumpNavigator {
    let viewModel: SessionViewModel
    let drag: DragCoordinator
    let mode: AllWorkspacesModeStore

    var isInMissionControl: Bool { drag.isGridShown && mode.active == .missionControl }

    var currentPlace: JumpPlace? {
        if isInMissionControl { return .missionControl }
        return viewModel.resolvedFocusedPaneID.map(JumpPlace.pane)
    }

    func openOldest() {
        let from = currentPlace
        if isInMissionControl {
            drag.closeGrid()
            Task { await viewModel.jumpToOldestAttentionToast(from: from) }
        } else {
            Task { await viewModel.jumpToOldestDisplayedAttentionToast(from: from) }
        }
    }

    func open(toast pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToAttentionToast(pane: pane, from: from) }
    }

    func open(pane: PaneID) {
        let from = currentPlace
        drag.closeGrid()
        Task { await viewModel.jumpToPane(pane, from: from) }
    }

    func back() {
        guard let target = viewModel.jumpBackTarget else { return }
        let from = currentPlace
        switch target {
        case .missionControl:
            viewModel.recordJump(from: from)
            mode.select(.missionControl)
            drag.openGrid()
        case .pane(let pane):
            open(pane: pane)
        }
    }
}
```

- [ ] **Step 6: Create the stores in FlockApp and inject them**

Beside `notificationLifetimeStore` (line 59 and 142-143), add `@State` stores the same way:

```swift
    @State private var allWorkspacesModeStore: AllWorkspacesModeStore
    @State private var dormantCutoffStore: DormantCutoffStore
    @State private var workspaceIdentityStore: WorkspaceIdentityStore
```

```swift
        _allWorkspacesModeStore = State(initialValue: AllWorkspacesModeStore())
        _dormantCutoffStore = State(initialValue: DormantCutoffStore())
        _workspaceIdentityStore = State(initialValue: WorkspaceIdentityStore())
```

Where the window's root view gets its `.environment(...)` chain (find with `grep -n ".environment(dragCoordinator)" Sources/Flock/FlockApp.swift`), add:

```swift
                .environment(allWorkspacesModeStore)
                .environment(dormantCutoffStore)
                .environment(workspaceIdentityStore)
```

The render harness builds `MainWindow` itself; add the same three `.environment` calls wherever `Tests/FlockChromeRender/ChromeRenderTests.swift` injects `DragCoordinator` (find with `grep -n "environment(drag" Tests/FlockChromeRender/ChromeRenderTests.swift`), each built over a fresh `UserDefaults(suiteName:)` so tests never read the real defaults. Do the same in `Tests/FlockChromeRender/WorkspaceClickLatencyTests.swift` if it builds `MainWindow`.

- [ ] **Step 7: The View menu**

Replace the two notification buttons (lines 534-545) with:

```swift
                Button(ViewCommand.openOldestNotification.title) { navigator.openOldest() }
                    .keyboardShortcut(ViewCommand.openOldestNotification.shortcut)
                    .disabled(viewModel.attentionToasts.isEmpty)
                    .accessibilityIdentifier(ViewCommand.openOldestNotification.accessibilityIdentifier)
                Button(ViewCommand.jumpBack.title) { navigator.back() }
                    .keyboardShortcut(ViewCommand.jumpBack.shortcut)
                    .disabled(viewModel.jumpBackTarget == nil)
                    .accessibilityIdentifier(ViewCommand.jumpBack.accessibilityIdentifier)
                // The only way to clear a "needs input" toast without
                // answering the pane or dismissing each one by hand.
                Button(ViewCommand.clearNotifications.title) { viewModel.clearAttentionToasts() }
                    .keyboardShortcut(ViewCommand.clearNotifications.shortcut)
                    .disabled(viewModel.attentionToasts.isEmpty)
                    .accessibilityIdentifier(ViewCommand.clearNotifications.accessibilityIdentifier)
```

with, in the same `commands` scope:

```swift
    private var navigator: JumpNavigator {
        JumpNavigator(viewModel: viewModel, drag: dragCoordinator, mode: allWorkspacesModeStore)
    }
```

- [ ] **Step 8: The palette**

In `PaletteCatalog.swift`'s `PaletteContext`, add `var canJumpBack = false`, and in `view(_:)`:

```swift
        if context.hasNotifications { commands += [(.view, .openOldestNotification), (.view, .clearNotifications)] }
        if context.canJumpBack { commands.append((.view, .jumpBack)) }
```

In `PaletteContext.current(...)` (PaletteRunner.swift) set `canJumpBack: viewModel.jumpBackTarget != nil`. Give `PaletteRunner` a `let modeStore: AllWorkspacesModeStore`, pass it from `CommandPaletteView.swift:213` (that view reads `@Environment(AllWorkspacesModeStore.self)`), and route:

```swift
            case .openOldestNotification:
                JumpNavigator(viewModel: viewModel, drag: dragCoordinator, mode: modeStore).openOldest()
            case .jumpBack:
                JumpNavigator(viewModel: viewModel, drag: dragCoordinator, mode: modeStore).back()
```

- [ ] **Step 9: The dock**

In `Sources/Flock/Views/AttentionToastStack.swift`, read `@Environment(DragCoordinator.self) private var drag` and `@Environment(AllWorkspacesModeStore.self) private var mode` in the card view and replace the tap action's task with:

```swift
            JumpNavigator(viewModel: viewModel, drag: drag, mode: mode).open(toast: toast.paneID)
```

- [ ] **Step 10: Run the tests**

Run: `xcodegen && RENDER PaletteShortcutTests && RENDER PaletteCatalogTests`
Expected: `** TEST SUCCEEDED **` twice.

- [ ] **Step 11: Commit**

```bash
git add -A Sources/Flock Tests/FlockChromeRender
Scripts/checks.sh && git commit -m "jump back on shift-cmd-J, clear notifications moves to shift-cmd-U"
```

### Task 11: Dormant cutoff in Settings

**Files:**
- Modify: `Sources/Flock/Views/Settings/NotificationSettingsSection.swift`, `Sources/Flock/Views/Settings/FlockSettingsView.swift`, `Sources/Flock/FlockApp.swift:577-584`

**Interfaces:**
- Consumes: `DormantCutoffStore` (Task 2, whose tests cover the choices and persistence), created in FlockApp in Task 10.

This task is a system `Form` row with no logic of its own, so it has no test of its own; Step 2's build and Task 14's hand-off check it.

- [ ] **Step 1: Implement**

```swift
struct NotificationSettingsSection: View {
    let store: NotificationLifetimeStore
    let cutoffStore: DormantCutoffStore

    var body: some View {
        Section("Notifications") {
            Picker(selection: Binding(get: { store.active }, set: { store.select($0) })) {
                ForEach(NotificationLifetime.allCases, id: \.self) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            } label: {
                Text("Show in sidebar")
                Text("When an agent finishes or needs your input. A question stays until you answer it.")
            }
            .accessibilityIdentifier("flock.settings.notificationLifetime")
            Picker(selection: Binding(get: { cutoffStore.active }, set: { cutoffStore.select($0) })) {
                ForEach(DormantCutoff.allCases, id: \.self) { cutoff in
                    Text(cutoff.displayName).tag(cutoff)
                }
            } label: {
                Text("Dormant after")
                Text("Mission control folds away a pane whose status has not changed for this long.")
            }
            .accessibilityIdentifier("flock.settings.dormantCutoff")
        }
    }
}
```

Add `let dormantCutoffStore: DormantCutoffStore` to `FlockSettingsView`, pass `cutoffStore: dormantCutoffStore`, and pass `dormantCutoffStore: dormantCutoffStore` at `FlockApp.swift:577`.

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add -A Sources/Flock/Views/Settings Sources/Flock/FlockApp.swift
Scripts/checks.sh && git commit -m "settings: Dormant after, under Notifications"
```

### Task 12: MissionControlView

**Files:**
- Create: `Sources/Flock/Views/MissionControl/MissionControlView.swift`, `Sources/Flock/Views/MissionControl/MissionCardView.swift`
- Modify: `Sources/Flock/Views/AllWorkspacesGrid.swift` (header and body), `Sources/Flock/Views/MainWindow.swift:35-41` (dock), `Sources/Flock/Theme/ChromeMetrics.swift`, `Sources/Flock/Theme/ChromeTypography.swift`
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (new tests beside `renderGrid`)

**Interfaces:**
- Consumes: `MissionBoard`, `MissionSelection`, `MissionAge`, `PaneStatusHistory.segments`, `RepoBranchCache`, `IdentityPalette`, `WorkspaceIdentityStore`, `AllWorkspacesModeStore`, `DormantCutoffStore`, `BoardStore`, `HerdProgressStore`, `JumpNavigator`.
- Produces: `MissionControlView(theme:viewModel:)`, `MissionCardView`, `StatusTimeline`, `ChromeMetrics.MissionControl`, ChromeType `mission*` fonts.

- [ ] **Step 1: Metrics and type**

Append to `ChromeMetrics.swift` (inside `enum ChromeMetrics`):

```swift
    enum MissionControl {
        static let canvasPadding: CGFloat = 24
        static let canvasVerticalPadding: CGFloat = 20
        static let laneGap: CGFloat = 16
        static let lanePadding: CGFloat = 12
        static let laneCornerRadius: CGFloat = 8
        static let laneHeaderSpacing: CGFloat = 8
        static let laneDot: CGFloat = 9
        static let cardGap: CGFloat = 10
        static let cardVerticalPadding: CGFloat = 12
        static let cardHorizontalPadding: CGFloat = 14
        static let cardCornerRadius: CGFloat = 6
        static let cardLineSpacing: CGFloat = 7
        static let cardDot: CGFloat = 7
        static let blockedOutline: CGFloat = 1.5
        static let selectionOutline: CGFloat = 2
        static let coolingOpacity: Double = 0.75
        static let timelineWidth: CGFloat = 180
        static let timelineHeight: CGFloat = 5
        static let timelineIdleHeight: CGFloat = 2
        static let groupLabelTopPadding: CGFloat = 6
        static let toggleHeight: CGFloat = 26
        static let toggleCornerRadius: CGFloat = 6
        static let toggleSegmentPadding: CGFloat = 12
        static let laneMoveDuration: Double = 0.2
    }
```

Append to `ChromeType` beside the `grid*` fonts:

```swift
    static let missionLaneTitle = inter(10.5, .semibold)
    static let missionLaneCount = inter(12)
    static let missionCardMeta = inter(11.5)
    static let missionCardTitle = inter(14.5, .medium)
    static let missionCardMono = mono(11)
    static let missionGroupLabel = inter(11.5, .medium)
    static let missionEmpty = inter(12.5)
    static func modeToggle(selected: Bool) -> Font { inter(12, selected ? .medium : .regular) }
```

- [ ] **Step 2: Write the failing render test**

Add to `ChromeRenderTests` beside `renderGrid` (it reuses the file's `Harness`, `GridFixture`, `settle`, `snapshot`, `hex`):

```swift
    func testMissionControlRendersInDarkAndLight() async throws {
        try await renderMissionControl(themed: "tokyo-night", into: "mission-dark.png")
        try await renderMissionControl(themed: "tokyo-night-day", into: "mission-light.png")
    }

    private func renderMissionControl(themed id: String, into file: String) async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
        var model = try GridFixture.model()
        let harness = try await Harness(theme: theme, model: model, client: GridFixtureClient(), attaching: [])
        model.panes[GridFixture.buildPane]?.agentStatus = .working
        harness.viewModel.update(model: model, connection: .live)
        model.panes[GridFixture.buildPane]?.agentStatus = .blocked
        harness.viewModel.update(model: model, connection: .live)
        harness.modeStore.select(.missionControl)
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
        let card = try XCTUnwrap(harness.missionCardFrame(of: GridFixture.buildPane), "the blocked pane is a Needs-you card")
        let outline = hex(image, CGPoint(x: card.minX + 0.75, y: card.midY))
        XCTAssertEqual(outline, theme.palette.red.hex, "\(id): a blocked card wears the blocked hue")
        window.close()
    }
```

The harness needs `modeStore` (the `AllWorkspacesModeStore` it injects, built over test defaults) and `missionCardFrame(of:)`, which reads frames the view publishes. Add to the harness:

```swift
    let modeStore = AllWorkspacesModeStore(userDefaults: UserDefaults(suiteName: "ChromeRenderTests.mode.\(UUID().uuidString)")!)
    @MainActor func missionCardFrame(of pane: PaneID) -> CGRect? { MissionCardFrames.shared.frames[pane] }
```

and inject `modeStore` instead of a fresh store in the environment chain added in Task 10.

- [ ] **Step 3: Run to see it fail**

Run: `RENDER ChromeRenderTests/testMissionControlRendersInDarkAndLight`
Expected: build failure, `cannot find 'MissionCardFrames' in scope`.

- [ ] **Step 4: MissionCardView and the timeline**

```swift
import FlockCore
import SwiftUI

/// Window-space frames of the cards on screen, read by render tests.
@MainActor
final class MissionCardFrames {
    static let shared = MissionCardFrames()
    var frames: [PaneID: CGRect] = [:]
}

struct MissionCardView: View {
    let theme: Theme
    let card: MissionCard
    /// The tab alone in Working, where the group label already names the
    /// workspace; `workspace › tab` elsewhere.
    let showsWorkspace: Bool
    let identity: Color?
    let repoBranch: RepoBranch
    let segments: [PaneStatusHistory.Segment]
    let now: Date
    let isSelected: Bool
    let isCooling: Bool
    let activate: () -> Void

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        VStack(alignment: .leading, spacing: M.cardLineSpacing) {
            HStack(spacing: 8) {
                StatusDot(status: card.status, theme: theme, size: M.cardDot)
                if showsWorkspace {
                    Text(card.workspaceName).foregroundStyle(identity ?? theme.textLabel)
                    Text("›").foregroundStyle(theme.textLabel)
                }
                Text(card.tabTitle).foregroundStyle(theme.textLabel)
                Spacer(minLength: 8)
                Text(ageText)
                    .font(ChromeType.missionCardMono)
                    .foregroundStyle(theme.agentStatusMarkColor(card.status))
            }
            .font(ChromeType.missionCardMeta)
            .lineLimit(1)
            Text(card.title)
                .font(ChromeType.missionCardTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text(repoBranch.text)
                    .font(ChromeType.missionCardMono)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                StatusTimeline(theme: theme, segments: segments)
                    .frame(width: M.timelineWidth, height: M.timelineHeight)
            }
        }
        .padding(.vertical, M.cardVerticalPadding)
        .padding(.horizontal, M.cardHorizontalPadding)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: M.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: M.cardCornerRadius)
                .strokeBorder(outline, lineWidth: outlineWidth)
        )
        .opacity(isCooling ? M.coolingOpacity : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
            activate()
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            MissionCardFrames.shared.frames[card.paneID] = $0
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate() }
        .accessibilityIdentifier("flock.mission.card.\(card.paneID.rawValue)")
    }

    private var ageText: String {
        let word = card.status.rawValue
        guard let since = card.since else { return word }
        return "\(word) \(MissionAge.text(now.timeIntervalSince(since)))"
    }

    private var outline: Color {
        if isSelected { return theme.accent }
        return card.status == .blocked ? theme.red : theme.rule
    }

    private var outlineWidth: CGFloat {
        isSelected ? M.selectionOutline : card.status == .blocked ? M.blockedOutline : ChromeMetrics.ruleWidth
    }
}

/// The last hour of one pane, oldest at the left: working, blocked and done
/// as solid bands, idle as a thin line, unrecorded time as the track alone.
struct StatusTimeline: View {
    let theme: Theme
    let segments: [PaneStatusHistory.Segment]

    var body: some View {
        GeometryReader { proxy in
            let total = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let width = total > 0 ? proxy.size.width * segment.end.timeIntervalSince(segment.start) / total : 0
                    band(segment.status)
                        .frame(width: width, height: proxy.size.height)
                }
            }
        }
        .background(theme.tabRest)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func band(_ status: AgentStatus?) -> some View {
        switch status {
        case .working?, .blocked?, .done?:
            Rectangle().fill(theme.agentStatusMarkColor(status!))
        case .idle?:
            Rectangle().fill(theme.green.opacity(0.55))
                .frame(height: ChromeMetrics.MissionControl.timelineIdleHeight)
        case .unknown?, nil:
            Color.clear
        }
    }
}
```

- [ ] **Step 5: MissionControlView**

```swift
import FlockCore
import SwiftUI

/// The All Workspaces view's mission-control mode. `MissionBoard` decides the
/// lanes; this draws them, refreshes ages once a minute, and moves the
/// keyboard selection.
struct MissionControlView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode
    @Environment(DormantCutoffStore.self) private var cutoff
    @Environment(WorkspaceIdentityStore.self) private var identity
    @Environment(BoardStore.self) private var boardNames
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var showsDormant = false

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = viewModel.currentTime > context.date ? viewModel.currentTime : context.date
            if let model = viewModel.model {
                let sections = RailSections(model: model, board: boardNames.names, herdProgress: herdProgress.progress)
                let board = MissionBoard(
                    model: model, sections: sections, toasts: viewModel.attentionToasts,
                    history: viewModel.statusHistory, cutoff: cutoff.active.seconds, now: now
                )
                lanes(board, sections: sections, now: now)
                    .onAppear {
                        if mode.missionSelection == nil { mode.missionSelection = MissionSelection.move(nil, .down, in: board.columns) }
                    }
            }
        }
        // On the focusable view itself: key presses reach the focused view
        // and its ancestors, never a child of it.
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .onKeyPress(.return) { activateSelection() }
        .padding(.horizontal, M.canvasPadding)
        .padding(.vertical, M.canvasVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            viewModel.repoBranches.invalidate()
        }
    }

    private func lanes(_ board: MissionBoard, sections: RailSections, now: Date) -> some View {
        HStack(alignment: .top, spacing: M.laneGap) {
            lane(title: "NEEDS YOU", status: .blocked, count: board.needsYou.count) {
                if board.needsYou.isEmpty {
                    Text("Nothing needs you").font(ChromeType.missionEmpty).foregroundStyle(theme.textLabel)
                }
                ForEach(board.needsYou) { card($0, sections: sections, now: now, showsWorkspace: true, cooling: false) }
            }
            lane(title: "WORKING", status: .working, count: board.working.reduce(0) { $0 + $1.cards.count }) {
                ForEach(board.working) { group in
                    groupLabel(group.name)
                    ForEach(group.cards) { card($0, sections: sections, now: now, showsWorkspace: false, cooling: false) }
                }
            }
            lane(title: "COOLING DOWN", status: .idle, count: board.coolingDown.count) {
                ForEach(board.coolingDown) { card($0, sections: sections, now: now, showsWorkspace: true, cooling: true) }
                Spacer(minLength: 0)
                dormantFold(board.dormant)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: M.laneMoveDuration), value: board)
    }

    private func lane<Content: View>(title: String, status: AgentStatus, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: M.cardGap) {
            HStack(spacing: M.laneHeaderSpacing) {
                StatusDot(status: status, theme: theme, size: M.laneDot)
                Text(title).font(ChromeType.missionLaneTitle).tracking(1.28).foregroundStyle(theme.textLabel)
                Text("\(count)").font(ChromeType.missionLaneCount).foregroundStyle(theme.textLabel)
            }
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: M.cardGap) { content() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                // Jump Back reopens on the card it left from.
                .onAppear { if let selected = mode.missionSelection { reader.scrollTo(selected) } }
                .onChange(of: mode.missionSelection) { _, selected in
                    if let selected { withAnimation { reader.scrollTo(selected) } }
                }
            }
        }
        .padding(M.lanePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: M.laneCornerRadius))
    }

    private func groupLabel(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(ChromeType.missionGroupLabel).foregroundStyle(theme.textLabel)
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
        }
        .padding(.top, M.groupLabelTopPadding)
    }

    private func card(_ card: MissionCard, sections: RailSections, now: Date, showsWorkspace: Bool, cooling: Bool) -> some View {
        MissionCardView(
            theme: theme, card: card, showsWorkspace: showsWorkspace,
            identity: identityColor(card.workspaceID, sections: sections),
            repoBranch: viewModel.repoBranches.repoBranch(for: card.folder),
            segments: viewModel.statusHistory.segments(of: card.paneID, at: now), now: now,
            isSelected: mode.missionSelection == card.paneID, isCooling: cooling,
            activate: { open(card.paneID) }
        )
        .id(card.paneID)
    }

    private func dormantFold(_ dormant: [MissionCard]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showsDormant.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsDormant ? "chevron.down" : "chevron.right")
                    Text("\(dormant.count) dormant").font(ChromeType.missionGroupLabel)
                }
                .foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flock.mission.dormant")
            if showsDormant {
                ForEach(dormant) { card in
                    HStack(spacing: 8) {
                        StatusDot(status: card.status, theme: theme, size: M.cardDot)
                        Text("\(card.workspaceName) › \(card.tabTitle)").foregroundStyle(theme.textLabel)
                        Text(card.title).foregroundStyle(theme.textDim)
                    }
                    .font(ChromeType.missionCardMeta)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { open(card.paneID) }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: M.cardCornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
    }

    private func identityColor(_ workspace: WorkspaceID, sections: RailSections) -> Color? {
        guard let key = WorkspaceIdentityStore.key(for: workspace, sections: sections),
              let index = identity.index(for: key)
        else { return nil }
        let colors = IdentityPalette.colors(for: theme.palette)
        return colors.indices.contains(index) ? Color(colors[index]) : nil
    }

    private func move(_ direction: MissionSelection.Direction) -> KeyPress.Result {
        guard let model = viewModel.model else { return .ignored }
        let board = MissionBoard(
            model: model, sections: RailSections(model: model, board: boardNames.names, herdProgress: herdProgress.progress),
            toasts: viewModel.attentionToasts, history: viewModel.statusHistory,
            cutoff: cutoff.active.seconds, now: viewModel.currentTime
        )
        mode.missionSelection = MissionSelection.move(mode.missionSelection, direction, in: board.columns)
        return .handled
    }

    private func activateSelection() -> KeyPress.Result {
        guard let pane = mode.missionSelection else { return .ignored }
        open(pane)
        return .handled
    }

    private func open(_ pane: PaneID) {
        mode.missionSelection = pane
        JumpNavigator(viewModel: viewModel, drag: drag, mode: mode).open(pane: pane)
    }
}
```

If `BoardStore` or `HerdProgressStore` expose their values under other names, use what `WorkspaceRail.swift:21` uses (`board.names`, `herdProgress.progress`).

- [ ] **Step 6: The header toggle and the mode switch in AllWorkspacesGrid**

Add `@Environment(AllWorkspacesModeStore.self) private var mode` and `@Environment(WorkspaceIdentityStore.self) private var identity` to `AllWorkspacesGrid`. Replace `header` with:

```swift
    private var header: some View {
        HStack(spacing: ChromeMetrics.Grid.headerSpacing) {
            modeToggle
            Text(workspaces.count == 1 ? "1 workspace" : "\(workspaces.count) workspaces")
                .font(ChromeType.gridCount)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
            if mode.active == .missionControl {
                Text("⌘J oldest  ·  ⇧⌘J back")
                    .font(ChromeType.gridHint)
                    .foregroundStyle(theme.textLabel)
            }
            Text("esc to return")
                .font(ChromeType.gridHint)
                .foregroundStyle(theme.textLabel)
        }
        .padding(.horizontal, ChromeMetrics.Grid.headerHorizontalPadding)
        .frame(height: ChromeMetrics.Grid.headerHeight)
        .background(WindowDragExclusion())
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(AllWorkspacesMode.allCases, id: \.self) { option in
                let on = mode.active == option
                Button { mode.select(option) } label: {
                    Text(option.title)
                        .font(ChromeType.modeToggle(selected: on))
                        .foregroundStyle(on ? theme.textStrong : theme.textLabel)
                        .padding(.horizontal, ChromeMetrics.MissionControl.toggleSegmentPadding)
                        .frame(height: ChromeMetrics.MissionControl.toggleHeight - 4)
                        .background(on ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.toggleCornerRadius - 2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flock.grid.mode.\(option.rawValue)")
            }
        }
        .padding(2)
        .background(theme.tabRest, in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.toggleCornerRadius))
    }
```

In `body`, draw `MissionControlView(theme: theme, viewModel: viewModel)` in place of the `ScrollView` when `mode.active == .missionControl`, and publish no grid items then: change `.onAppear { drag.setGridOrder(itemOrder) }` and its `.onChange` to pass `mode.active == .arrange ? itemOrder : []`, adding `.onChange(of: mode.active) { drag.setGridOrder(mode.active == .arrange ? itemOrder : []) }`.

- [ ] **Step 7: Hide the floating dock in mission control**

In `MainWindow.swift`, read `@Environment(AllWorkspacesModeStore.self) private var allWorkspacesMode` and wrap the `MessageDock` overlay in `if allWorkspacesMode.active == .arrange { ... }`, with a comment that Needs you stands in for the dock there.

- [ ] **Step 8: Run the render test and look at both PNGs**

```bash
mkdir -p build/render && TEST_RUNNER_FLOCK_GRID_RENDER_DIR=$PWD/build/render \
  xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' \
  -only-testing:FlockChromeRender/ChromeRenderTests/testMissionControlRendersInDarkAndLight \
  -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. Then open `build/render/mission-dark.png` and `mission-light.png` with the Read tool and compare them with board 05/05b. Write down anything that reads wrong (lane headers, card spacing, timeline visibility in light, the selection ring) and fix it before committing.

- [ ] **Step 9: Commit**

```bash
git add -A Sources/Flock Tests/FlockChromeRender
Scripts/checks.sh && git commit -m "mission control: needs you, working and cooling down lanes behind the All Workspaces toggle"
```

---

## Milestone 3: Arrange as islands

### Task 13: Islands, fit to window, dormant chips

**Files:**
- Modify: `Sources/Flock/Views/AllWorkspacesGrid.swift` (`body` scroll content, `WorkspaceCard` becomes `WorkspaceIsland`, `TabThumbnail`, `TabHandleStrip`, `MiniPane`, `NewTabPlaceholder`)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift` (`Grid` constants), `Sources/Flock/Theme/ChromeTypography.swift`
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (`assertGridSamples`, `renderGrid`, new island test)

**Interfaces:**
- Consumes: `IslandLayout`, `IslandFitHold`, `MissionBoard.dormantWorkspaces`, `WorkspaceIdentityStore`, `IdentityPalette`, `RailSections`.
- Produces: environment value `\.gridThumbnailSize: CGSize` read by `TabThumbnail` and `NewTabPlaceholder` in place of `ChromeMetrics.Grid.thumbnailWidth/Height`.

- [ ] **Step 1: Write the failing render test**

Beside `renderGrid`:

```swift
    func testArrangeDrawsTintedIslandsThatFillTheWindow() async throws {
        for (id, file) in [("tokyo-night", "islands-dark.png"), ("tokyo-night-day", "islands-light.png")] {
            let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
            harness.modeStore.select(.arrange)
            let window = harness.makeWindow(size: Self.gridWindowSize)
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
            }
            let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
            XCTAssertGreaterThan(thumbnail.width, ChromeMetrics.Grid.minimumThumbnailWidth, "\(id): a roomy window buys bigger thumbnails")
            let islandGround = hex(image, CGPoint(x: thumbnail.minX - 8, y: thumbnail.midY))
            XCTAssertNotEqual(islandGround, theme.palette.chromeRoles.canvas.hex, "\(id): the island is tinted, not bare canvas")
            window.close()
        }
    }
```

- [ ] **Step 2: Run to see it fail**

Run: `RENDER ChromeRenderTests/testArrangeDrawsTintedIslandsThatFillTheWindow`
Expected: build failure, `type 'ChromeMetrics.Grid' has no member 'minimumThumbnailWidth'`.

- [ ] **Step 3: Metrics**

In `ChromeMetrics.Grid` add the constants below; at the end of Step 7 delete any `Grid` constant nothing references any more:

```swift
        static let minimumThumbnailWidth: CGFloat = 120
        static let islandCornerRadius: CGFloat = 14
        static let islandTint: Double = 0.10
        static let islandCurrentOutline: CGFloat = 1.5
        static let islandHeaderSpacing: CGFloat = 10
        static let identitySquare: CGFloat = 14
        static let identitySquareRadius: CGFloat = 4
        static let selectedHandleTint: Double = 0.25
        static let dormantChipHeight: CGFloat = 26
        static let dormantChipSpacing: CGFloat = 8
        static let dormantDwell: Duration = .milliseconds(500)
```

Set `tabStripHeight = 24`, `thumbnailCornerRadius = 6`, `miniPaneCornerRadius = 4`, `miniPaneVerticalPadding = 8`, `miniPaneHorizontalPadding = 9`, `miniPaneStatusDot = 6`, `canvasPadding = 28`. In `ChromeType`: `gridCardName = inter(18, .semibold)`, `gridCardMeta = inter(12)`, `gridTabLabel(selected:)` sizes 12 with `.semibold`/`.medium`, `gridMiniPaneTitle = inter(11.5)`, and add `gridMiniPaneStatus = mono(10)`.

`IslandLayout.Metrics()` must agree with these: header 46 = 14 top + 20 header row + 12 gap; padding 16; gaps 28 and 8. If you change one, change both and say so in the commit.

- [ ] **Step 4: The thumbnail size environment value**

```swift
private struct GridThumbnailSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: ChromeMetrics.Grid.thumbnailWidth, height: ChromeMetrics.Grid.thumbnailHeight)
}

extension EnvironmentValues {
    var gridThumbnailSize: CGSize {
        get { self[GridThumbnailSizeKey.self] }
        set { self[GridThumbnailSizeKey.self] = newValue }
    }
}
```

`TabThumbnail` and `NewTabPlaceholder` read `@Environment(\.gridThumbnailSize)` and use its height where they used `ChromeMetrics.Grid.thumbnailHeight`; the cell's `.frame(width:)` uses its width.

- [ ] **Step 5: The grid body lays out islands**

Replace the `ScrollView` content's `ForEach(GridCardLayout.cardRows(workspaces)...)` with rows from the fit:

```swift
    @State private var hold = IslandFitHold()
    @State private var viewport: CGSize = .zero
    @State private var expandedDormant: Set<WorkspaceID> = []
    @Environment(BoardStore.self) private var boardNames
    @Environment(HerdProgressStore.self) private var herdProgress
    @Environment(DormantCutoffStore.self) private var cutoff

    private var sections: RailSections? {
        viewModel.model.map { RailSections(model: $0, board: boardNames.names, herdProgress: herdProgress.progress) }
    }

    private var railOrdered: [WorkspaceRecord] {
        guard let sections, let model = viewModel.model else { return workspaces }
        let ids = sections.workspaces.map(\.workspaceID) + sections.board.map(\.workspaceID) + sections.herds.map(\.workspaceID)
        return ids.compactMap { id in model.workspaces.first { $0.workspaceID == id } }
    }

    private var dormant: Set<WorkspaceID> {
        guard let model = viewModel.model, let sections else { return [] }
        return MissionBoard(
            model: model, sections: sections, toasts: viewModel.attentionToasts,
            history: viewModel.statusHistory, cutoff: cutoff.active.seconds, now: viewModel.currentTime
        ).dormantWorkspaces.subtracting(expandedDormant)
    }

    private var fit: IslandLayout.Fit {
        let islands = railOrdered.filter { !dormant.contains($0.workspaceID) }.map {
            IslandLayout.Island(id: $0.workspaceID, tabs: viewModel.model?.tabs[$0.workspaceID]?.count ?? 1)
        }
        var hold = hold
        return hold.update(islands, in: viewport, hasDormantStrip: !dormant.isEmpty, dragging: drag.activeSubject != nil)
    }
```

`fit` reads a copy, so it never writes state from `body`. The stored `hold` must still be the fit on screen when a drag starts, so update it, with the same arguments, on appear and on every change of `viewport`, of the island list (`[IslandLayout.Island]` is `Equatable`) and of `dormant.isEmpty`, each only while `drag.activeSubject == nil`. Once a drag is live, `fit` returns the stored fit. Measure `viewport` with `.onGeometryChange(for: CGSize.self)` on the `ScrollView`, minus `2 * ChromeMetrics.Grid.canvasPadding` on each axis.

Scroll content:

```swift
                VStack(alignment: .leading, spacing: IslandLayout.Metrics().islandGap) {
                    ForEach(fit.rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: IslandLayout.Metrics().islandGap) {
                            ForEach(row, id: \.self) { id in
                                if let workspace = workspaces.first(where: { $0.workspaceID == id }) {
                                    WorkspaceIsland(
                                        theme: theme, viewModel: viewModel, workspace: workspace,
                                        slotsPerRow: fit.tabsPerRow[id] ?? 1,
                                        identity: identityColor(id)
                                    )
                                }
                            }
                        }
                    }
                    if !dormant.isEmpty { dormantStrip }
                }
                .environment(\.gridThumbnailSize, CGSize(width: fit.thumbnailWidth, height: fit.thumbnailHeight))
```

`itemOrder` uses `fit.tabsPerRow[workspace.workspaceID] ?? 1` per workspace instead of the grid-wide `slotsPerRow`, iterates `railOrdered`, and for a dormant workspace publishes `.card(id)` only. Remove the now unused `slotsPerRow`, `contentWidth` and the `GridCardLayout.rowWidth`/`tabsPerRow` calls; keep `GridCardLayout.cells`, `rows`, `insertIndex`, `landingSlot` and `surviving`, which the drop logic still uses.

Prune and assign identity colours when the view appears:

```swift
        .onAppear {
            guard let sections else { return }
            let keys = railOrdered.compactMap { WorkspaceIdentityStore.key(for: $0.workspaceID, sections: sections) }
            identity.keepOnly(Set(keys))
            identity.assign(keys)
        }

    private func identityColor(_ id: WorkspaceID) -> Color? {
        guard let sections, let key = WorkspaceIdentityStore.key(for: id, sections: sections),
              let index = identity.index(for: key) else { return nil }
        let colors = IdentityPalette.colors(for: theme.palette)
        return colors.indices.contains(index) ? Color(colors[index]) : nil
    }
```

- [ ] **Step 6: WorkspaceIsland**

Rename `WorkspaceCard` to `WorkspaceIsland`, add `let identity: Color?`, and change only its drawing:

```swift
        .padding(.top, 14)
        .padding(.bottom, IslandLayout.Metrics().bottomPadding)
        .padding(.horizontal, IslandLayout.Metrics().horizontalPadding)
        .fixedSize(horizontal: true, vertical: false)
        .background((identity ?? theme.textLabel).opacity(ChromeMetrics.Grid.islandTint), in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.islandCornerRadius))
        .overlay { DropWash(theme: theme, isTargeted: takesTheDrop, cornerRadius: ChromeMetrics.Grid.islandCornerRadius) }
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.islandCornerRadius)
                .strokeBorder(outline(tabs), lineWidth: ChromeMetrics.Grid.islandCurrentOutline)
        )
```

where `outline(tabs)` is `theme.accent` while targeted (as today), the identity colour for the focused workspace (`workspace.workspaceID == viewModel.model?.focusedWorkspaceID`), and `.clear` otherwise. The header becomes:

```swift
        HStack(spacing: ChromeMetrics.Grid.islandHeaderSpacing) {
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.identitySquareRadius)
                .fill(identity ?? theme.textLabel)
                .frame(width: ChromeMetrics.Grid.identitySquare, height: ChromeMetrics.Grid.identitySquare)
            Text(workspace.label).font(ChromeType.gridCardName).foregroundStyle(theme.textStrong).lineLimit(1)
            StatusDot(status: workspace.agentStatus, theme: theme, size: ChromeMetrics.Grid.cardStatusDot + 2)
            Spacer(minLength: 0)
            Text(tabCount == 1 ? "1 tab" : "\(tabCount) tabs").font(ChromeType.gridCardMeta).foregroundStyle(theme.textLabel)
        }
        .frame(height: 20)
        .padding(.bottom, 12)
        .contextMenu { colourMenu }
```

`colourMenu` lists `IdentityPalette.colors(for: theme.palette)` as eight buttons ("Colour 1" ... "Colour 8", each with a filled circle image in that colour) plus "Automatic", calling `identity.setOverride(index or nil, for: key)`; it is empty for a herd (no key). Add a FlockCore-free accessibility identifier `flock.grid.island.colour.\(index)` to each.

- [ ] **Step 7: Thumbnail, handle and mini pane drawing**

- `TabThumbnail`: background `theme.pane` (was `canvas`), no stroke.
- `TabHandleStrip`: add `var fill: Color? = nil`; background `fill ?? .clear`; drop the accent bar (keep its zero-width slot out); title `theme.textDim` unless focused (`theme.textStrong`). In the island, pass `fill: identity.opacity(ChromeMetrics.Grid.selectedHandleTint)` for the focused workspace's focused tab only. The drag proxy keeps calling it with no `fill`.
- `MiniPane`: background `theme.tabRest`; stroke only when `status == .blocked` (`theme.red`, 1.5) or `isPreviewed` (`theme.accent`); content becomes a `VStack(alignment: .leading, spacing: 4)` of `HStack { StatusDot; Text(status.rawValue).font(ChromeType.gridMiniPaneStatus) }` and `Text(title).font(ChromeType.gridMiniPaneTitle).lineLimit(3)`.

- [ ] **Step 8: The dormant strip**

```swift
    private var dormantStrip: some View {
        HStack(spacing: ChromeMetrics.Grid.dormantChipSpacing) {
            Text("DORMANT").font(ChromeType.missionLaneTitle).tracking(1.28).foregroundStyle(theme.textLabel)
            ForEach(railOrdered.filter { dormant.contains($0.workspaceID) }, id: \.workspaceID) { workspace in
                HStack(spacing: 7) {
                    StatusDot(status: workspace.agentStatus, theme: theme, size: 8)
                    Text(workspace.label).font(ChromeType.gridCardMeta).foregroundStyle(theme.textDim)
                }
                .padding(.horizontal, 10)
                .frame(height: ChromeMetrics.Grid.dormantChipHeight)
                .background(theme.chrome, in: Capsule())
                .overlay { DropWash(theme: theme, isTargeted: CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model).takesTheDrop, cornerRadius: ChromeMetrics.Grid.dormantChipHeight / 2) }
                .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .card(workspace.workspaceID)) }
                .onTapGesture { expandedDormant.insert(workspace.workspaceID) }
                .task(id: CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model).takesTheDrop) {
                    guard CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model).takesTheDrop else { return }
                    try? await Task.sleep(for: ChromeMetrics.Grid.dormantDwell)
                    guard !Task.isCancelled else { return }
                    expandedDormant.insert(workspace.workspaceID)
                }
                .accessibilityIdentifier("flock.grid.dormant.\(workspace.workspaceID.rawValue)")
            }
        }
    }
```

Clear `expandedDormant` in `.onDisappear`.

- [ ] **Step 9: Bring the existing grid render tests up to date**

Run: `RENDER ChromeRenderTests`
For each failing grid test, apply this rule. An assertion that samples the old card look (the `paneBorder` card outline, `pane` card ground, the 3pt focus bar, the `tabStripFill` band) is replaced with the island equivalent: card ground becomes the island tint (not `canvas`), the outline sample moves to the focused island's identity outline, the handle band sample becomes "not the thumbnail body" only for the focused tab. In `assertGridSamples` the samples become:

```swift
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/header", CGPoint(x: 450, y: 28), roles.chrome),
            ("rule/header", CGPoint(x: 450, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 5, y: 120), roles.canvas),
```

An assertion that encodes drop behaviour (landing slots, insertion index, the new-tab placeholder following the dragged tab, the reorder slide, the proxy matching its thumbnail) must keep passing unchanged: if one fails, the island code is wrong, so fix the code. Rerun until the suite is green.

- [ ] **Step 10: Render both themes and look**

```bash
mkdir -p build/render && TEST_RUNNER_FLOCK_GRID_RENDER_DIR=$PWD/build/render \
  xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' \
  -only-testing:FlockChromeRender/ChromeRenderTests/testArrangeDrawsTintedIslandsThatFillTheWindow \
  -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -20
```

Read `build/render/islands-dark.png` and `islands-light.png`; compare with board 10. Check that the gap between islands clearly beats the gap inside one, the tints are distinct but quiet in light, and the blocked mini pane is the only outline inside an island. Fix what reads wrong.

- [ ] **Step 11: Commit**

```bash
git add -A Sources/Flock Tests/FlockChromeRender
Scripts/checks.sh && git commit -m "arrange: workspaces as tinted islands sized to fill the window, dormant ones as chips"
```

### Task 14: Hand off

**Files:** none new.

- [ ] **Step 1: Run every test the branch touched**

```bash
for t in PaneStatusHistoryTests DormantCutoffTests MissionBoardTests RepoBranchTests JumpBackTests AllWorkspacesModeTests IdentityPaletteTests WorkspaceIdentityStoreTests IslandLayoutTests MissionJumpTests AttentionToastTests AllWorkspacesGridTests RailSectionsTests; do CORE $t; done
RENDER ChromeRenderTests && RENDER PaletteShortcutTests && RENDER PaletteCatalogTests
Scripts/checks.sh
```

Expected: every run `** TEST SUCCEEDED **`; checks print `ok`.

- [ ] **Step 2: Build Flock Dev for Matt**

```bash
Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev
```

Tell Matt to click "New build · Restart" in Flock Dev, then try: ⇧⌘R (opens mission control), a card click and ⇧⌘J back, ⌘J with a blocked pane, the toggle to Arrange, a pane drag onto an island and onto a dormant chip, and the Colour menu on an island header.
