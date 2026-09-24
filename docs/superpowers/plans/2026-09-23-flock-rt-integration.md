# rt in flock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** open `rt nav`, `rt glitter`, `rt run` and `rt runner` from any flock pane in a modal terminal backed by a hidden herdr pane, with long-running work kept alive, counted on a per-pane rt button, and shut down with its pane.

**Architecture:** A new `FlockCore/Rt` layer owns everything rt: labels that mark flock-owned workspaces and link hidden tabs to a pane's `terminal_id`, a pure lifecycle state machine per command, a thin herdr wire wrapper, and an `@Observable` `RtCoordinator` that opens, watches, closes, shuts down and re-adopts items. `SessionViewModel` keeps the full model for the coordinator and hands every existing view a model with flock-owned workspaces filtered out, so no existing surface can show them. The app adds legend buttons, an in-window modal that hosts hidden tabs through the existing ghostty surfaces, and a key monitor for ⌘W.

**Tech Stack:** Swift 6, SwiftUI + AppKit, libghostty surfaces (existing), herdr socket API (existing `HerdrCommandClient`), XCTest, xcodegen, Pen (design canvas via the pencil MCP).

**Spec:** `docs/superpowers/specs/2026-09-23-flock-rt-integration-design.md`. Read it before starting any task; this plan argues from it.

## Global Constraints

- Every rt surface renders only when `rt` resolves on flock's startup PATH (`ToolPath.resolved`).
- Public repo: no employer, customer, internal host, ticket id or private link in code, fixtures, docs or commit messages. Fixtures use `acme`. `Scripts/checks.sh` enforces it.
- No em or en dashes anywhere (`checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration, no decision history, no references to this plan or its tasks.
- Tests stay hermetic: no test spawns rt, herdr, herdr-chat or deck, reads `~/.mattstack`, or reaches the network.
- herdr: never `herdr server stop`, never `pane.scroll`, never `layout.apply` on live panes.
- Run `xcodegen` after adding or removing files; run `Scripts/checks.sh` after `git add`.
- Build and test with a scratch derived data path: `-derivedDataPath "${TMPDIR}flock-rt-dd"`.
- Flock-owned workspace labels: `flock:rt` (shared) and `flock:rt runner <terminal>` (one per runner).
- Tab labels in flock-owned workspaces: `<kind> <terminal> <token>`, kind one of `nav`, `glitter`, `run`, `runner`.
- Typed lines: `command rt <args> [>"$FLOCK_RT_OUT"]; echo $? >"$FLOCK_RT_STATUS"` (`$status` for fish).
- Clean exit statuses: 0 and 130.
- Poll 300 ms; never-seen-busy ceiling 3 s (also the grace for a job that ended without writing its status); confirm delay 1 s; shutdown wait 10 s; shell wait 2 s; 10 unanswered polls before an item is taken as gone.
- rt's files live under `ScratchDirectory.url/rt`, never directly in `$TMPDIR`.
- Shutdown: `ctrl+c` with `pane.send_keys`, then `y` only if `rt-ui` still holds the foreground a second later.
- UI tasks do not start until the design canvas (Task 11) is approved by Matt. A UI change is not done until rendered in a dark and a light theme and looked at.
- Never quit, kill or launch Matt's Flock apps. Finished work goes to `Scripts/dev-build.sh`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **A just-created tab absent from the next model:** the event naming a new tab can lag herdr's answer to `tab.create`, so an item must not be dropped as "closed" before its tab was ever seen. Pinned in Task 9 (`testANewTabNotYetInTheModelIsNotDropped`).
2. **A herdr that sends no terminal ids:** links cannot be judged, so nothing may be reaped or adopted, or every hidden runner dies on launch. Pinned in Task 9 (`testWithoutTerminalIDsNothingIsReaped`).
3. **A fish shell:** `$?` is not fish; the status suffix must read `$status`, or every command reads as unclean. Pinned in Task 4 and Task 8 (`testAFishShellGetsItsStatusVariable`).
4. **A folder with a quote in its name:** "cd here" and phase 2 type paths into a shell; an unquoted `'` breaks the line or runs something else. Pinned in Task 4 (`testQuotingSurvivesASingleQuote`).
5. **⌘W while the modal is up:** it must close the modal, not the window, and a strip's "any key" must not swallow ⌘Q. Pinned in Task 7 (`RtModalKeyTests`).

---

## File Structure

FlockCore (logic, tested without a window):

| File | Responsibility |
|---|---|
| `Sources/FlockCore/Herdr/HerdrModel.swift` (modify) | `TerminalID`; `PaneRecord.terminalID` |
| `Sources/FlockCore/Store/HerdrStore.swift` (modify) | predicted records keep `terminalID` |
| `Sources/FlockCore/Rt/RtLabels.swift` | `RtKind`, flock-owned predicate, label format and parse |
| `Sources/FlockCore/Rt/VisibleSession.swift` | `SessionModel.withoutFlockOwned` |
| `Sources/FlockCore/ViewModels/SessionViewModel.swift` (modify) | full vs visible model; owns `rt`; `canvasFocusedPaneID` |
| `Sources/FlockCore/Rt/RtCommandLine.swift` | `ShellFlavor`, quoting, typed lines |
| `Sources/FlockCore/Rt/RtFiles.swift` | `RtFilePaths`, `RtFileStore`, `DiskRtFileStore`, `RunResolveResult`, `RtFileParse` |
| `Sources/FlockCore/Herdr/PaneForegroundJob.swift` (modify) | `Snapshot` (busy, shell name, foreground names) |
| `Sources/FlockCore/Rt/RtLifecycle.swift` | one command's state machine |
| `Sources/FlockCore/Rt/RtHerdr.swift` | herdr verbs and wire shapes |
| `Sources/FlockCore/Rt/RtItem.swift` | `RtItem`, `RtStrip`, `RtModal`, `RtButtonModel`, `RtMenuRow`, `RtMenuModel`, `RtModalKey` |
| `Sources/FlockCore/Rt/RtCoordinator.swift` | open, watch, outcomes, modal |
| `Sources/FlockCore/Rt/RtCoordinator+Lifetime.swift` | shutdown, adoption, strays, reaping, focus |

App:

| File | Responsibility |
|---|---|
| `Sources/Flock/Rt/RtBrand.swift` | rt's plum and pink; `RtAvailability` |
| `Sources/Flock/Rt/RtButton.swift` | the rt button (split pill), `RtBadge` |
| `Sources/Flock/Rt/RtPopover.swift` | the rt popover |
| `Sources/Flock/Views/PopoverAppearancePin.swift` | the popover window's appearance, shared with chat |
| `Sources/Flock/Rt/RtModalView.swift` | the overlay and its chrome (title row, tab strip, strip) |
| `Sources/Flock/Rt/RtModalPane.swift` | a hidden tab's one pane on its ghostty surface |
| `Sources/Flock/Rt/RtModalKeyMonitor.swift` | ⌘W and any-key while the modal is up |
| `Sources/Flock/Theme/ChromeMetrics.swift`, `ChromeTypography.swift` (modify) | rt metrics and fonts |
| `Sources/Flock/Views/PaneLauncherOverlay.swift` (modify) | `NavigatorRoster` reads `RtBrand` |
| `Sources/Flock/Views/PaneCellView.swift`, `PaneCanvas.swift`, `MainWindow.swift` (modify) | wiring; the modal overlays the tab area only |
| `docs/design/rt/` | `flock-rt.pen`, reference PNGs, `measurements.md` |

Tests: `Tests/FlockCoreTests/` gains `TerminalIDTests`, `RtLabelsTests`, `VisibleSessionTests`, `RtCommandLineTests`, `RtFilesTests`, `RtLifecycleTests`, `RtHerdrTests`, `RtItemTests`, `RtTestSupport` (fixtures and `FakeRtWorld`), `RtCoordinatorTests`, `RtCoordinatorLifetimeTests`, plus additions to `SessionViewModelTests`, `PaneForegroundJobTests`, `HerdrStoreTests`. `Tests/FlockChromeRender/` gains `RtLegendRenderTests` and `RtModalChromeRenderTests`.

Test command used throughout (swap the class name):

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' \
  -only-testing:FlockCoreTests/RtLabelsTests -skipPackagePluginValidation \
  -derivedDataPath "${TMPDIR}flock-rt-dd" 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -5
```

Render tests use `-scheme FlockChromeRender -only-testing:FlockChromeRender/<Class>`.

---

### Task 1: Terminal ids on pane records

**Files:**
- Modify: `Sources/FlockCore/Herdr/HerdrModel.swift` (add `TerminalID` after `PaneID`; `PaneRecord`)
- Modify: `Sources/FlockCore/Store/HerdrStore.swift:390-403` (two `PaneRecord(...)` constructions)
- Create: `Tests/FlockCoreTests/TerminalIDTests.swift`
- Modify: `Tests/FlockCoreTests/HerdrStoreTests.swift` (one new test and fixture)

**Interfaces:**
- Produces: `public struct TerminalID: Hashable, Codable, RawRepresentable, Sendable`; `PaneRecord.terminalID: TerminalID?` (decoded from `terminal_id`, default `nil`).

- [ ] **Step 0: Make the worktree buildable**

The worktree lacks the gitignored build inputs. Link them from the main checkout (they are symlinks, never copies), exclude the links from git, and initialize the ghostty submodule (its objects are already local):

```bash
cd /Users/matt/Documents/GitHub/flock/.worktrees/rt-integration
for p in Vendor/GhosttyKit.xcframework Vendor/zig Vendor/libghostty.version Vendor/Sparkle \
  Sources/Flock/Resources/herdr-mouse-patch-0.9.1-arm64 \
  Sources/Flock/Resources/herdr-mouse-patch-0.9.1-arm64.LICENSE \
  Sources/Flock/Resources/herdr-mouse-patch-0.9.1-arm64.provenance.txt; do
  [ -e "$p" ] || ln -s "/Users/matt/Documents/GitHub/flock/$p" "$p"
done
grep -qx '/Vendor/Sparkle' "$(git rev-parse --git-common-dir)/info/exclude" || \
  printf '/Vendor/Sparkle\n/Vendor/GhosttyKit.xcframework\n/Vendor/zig\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
git submodule update --init Vendor/ghostty
git status --short
```

Expected: `git status --short` prints nothing.

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/TerminalIDTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class TerminalIDTests: XCTestCase {
    func testAPaneRecordCarriesHerdrsTerminalID() throws {
        let json = #"{"pane_id":"w1:p1","terminal_id":"term_18c2f0a1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/acme"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        XCTAssertEqual(pane.terminalID, TerminalID(rawValue: "term_18c2f0a1"))
    }

    func testAPaneRecordWithoutOneStillDecodes() throws {
        let json = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/acme"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        XCTAssertNil(pane.terminalID)
    }
}
```

In `Tests/FlockCoreTests/HerdrStoreTests.swift`, add a fixture next to `twoTabSnapshotResultJSON()`:

```swift
private func twoTabSnapshotWithTerminalResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":1,"agent_status":"unknown"},{"tab_id":"w1:t2","workspace_id":"w1","label":"t2","number":2,"pane_count":0,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term_a1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[]}}
    """#
}
```

and a test next to `testExecutePublishesTheOverlayBeforeTheWireRoundTripCompletes`:

```swift
    /// A move re-keys the pane but keeps its PTY, so the predicted record
    /// must keep the terminal too: rt's links key on it.
    @MainActor
    func testAPredictedMoveKeepsTheTerminal() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotWithTerminalResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let hold = fake.holdNext(method: "pane.move")
        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        let task = Task { await store.execute(plan) }
        try await waitUntil { store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID == TabID(rawValue: "w1:t2") }

        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.terminalID, TerminalID(rawValue: "term_a1"))
        hold()
        _ = await task.value
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodegen` then the test command for `TerminalIDTests` and `HerdrStoreTests/testAPredictedMoveKeepsTheTerminal`.
Expected: compile failure, `cannot find 'TerminalID' in scope`.

- [ ] **Step 3: Implement**

In `HerdrModel.swift`, after `PaneID`:

```swift
public struct TerminalID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
```

In `PaneRecord`, after `public var scroll: ScrollInfo?`:

```swift
    /// herdr's handle on the pane's PTY. Unlike `paneID` it survives a move to
    /// another workspace, which is why rt's links key on it.
    public var terminalID: TerminalID? = nil
```

and in its `CodingKeys` add `case terminalID = "terminal_id"`.

In `HerdrStore.swift`, both predicted records (`movePaneToTab` and `renamePane`) gain `, terminalID: old.terminalID` as the last argument, e.g.:

```swift
            let moved = PaneRecord(
                paneID: pane, workspaceID: workspaceID, tabID: tab, focused: old.focused, agentStatus: old.agentStatus,
                revision: old.revision, terminalTitleStripped: old.terminalTitleStripped, label: old.label, cwd: old.cwd, scroll: old.scroll,
                terminalID: old.terminalID
            )
```

- [ ] **Step 4: Run the tests to see them pass**

Run the same command. Expected: all pass. Then run the whole `FlockCoreTests` once; expected: no regressions (every existing `PaneRecord(...)` call compiles because the new parameter defaults to `nil`).

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "herdr: decode each pane's terminal id and keep it through predicted moves

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Flock-owned labels and the visible model

**Files:**
- Create: `Sources/FlockCore/Rt/RtLabels.swift`
- Create: `Sources/FlockCore/Rt/VisibleSession.swift`
- Create: `Tests/FlockCoreTests/RtLabelsTests.swift`
- Create: `Tests/FlockCoreTests/VisibleSessionTests.swift`

**Interfaces:**
- Consumes: `TerminalID` (Task 1).
- Produces:
  - `public enum RtKind: String, Sendable, CaseIterable { case nav, glitter, run, runner }`
  - `public enum RtLabels` with `sharedWorkspace: String`, `runnerWorkspacePrefix: String`, `isFlockOwned(workspaceLabel:) -> Bool`, `runnerWorkspaceLabel(linkedTo: TerminalID) -> String`, `struct TabLink { kind: RtKind; terminal: TerminalID; token: String }`, `tabLabel(_ TabLink) -> String`, `tabLink(fromLabel:) -> TabLink?`
  - `extension SessionModel { public var withoutFlockOwned: SessionModel }`

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtLabelsTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class RtLabelsTests: XCTestCase {
    func testTheSharedAndRunnerWorkspacesAreFlockOwnedAndNothingElse() {
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt"))
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt runner term_a1"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "acme"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "flock:rtx"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "my flock:rt"))
    }

    func testARunnerWorkspaceNamesItsTerminal() {
        XCTAssertEqual(RtLabels.runnerWorkspaceLabel(linkedTo: TerminalID(rawValue: "term_a1")), "flock:rt runner term_a1")
    }

    func testATabLabelRoundTrips() {
        let link = RtLabels.TabLink(kind: .run, terminal: TerminalID(rawValue: "term_18c2f0a1"), token: "3f2a")
        XCTAssertEqual(RtLabels.tabLabel(link), "run term_18c2f0a1 3f2a")
        XCTAssertEqual(RtLabels.tabLink(fromLabel: "run term_18c2f0a1 3f2a"), link)
    }

    func testAnythingElseIsNotALink() {
        XCTAssertNil(RtLabels.tabLink(fromLabel: "zsh"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "build term_a1 3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run  3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1 3f2a extra"))
    }
}
```

`Tests/FlockCoreTests/VisibleSessionTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class VisibleSessionTests: XCTestCase {
    private func model(focusedWorkspace: String, focusedTab: String, focusedPane: String) -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspace)","focused_tab_id":"\#(focusedTab)","focused_pane_id":"\#(focusedPane)",
         "workspaces":[{"workspace_id":"w1","label":"acme","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},
                       {"workspace_id":"wF","label":"flock:rt","number":2,"active_tab_id":"wF:t1","agent_status":"unknown"},
                       {"workspace_id":"wR","label":"flock:rt runner term_a1","number":3,"active_tab_id":"wR:t1","agent_status":"unknown"}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"main","number":1,"pane_count":1,"agent_status":"unknown"},
                 {"tab_id":"wF:t1","workspace_id":"wF","label":"nav term_a1 tok1","number":1,"pane_count":1,"agent_status":"unknown"},
                 {"tab_id":"wR:t1","workspace_id":"wR","label":"runner term_a1 tok2","number":1,"pane_count":1,"agent_status":"unknown"}],
         "panes":[{"pane_id":"w1:p1","terminal_id":"term_a1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"},
                  {"pane_id":"wF:p1","terminal_id":"term_f1","workspace_id":"wF","tab_id":"wF:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"},
                  {"pane_id":"wR:p1","terminal_id":"term_r1","workspace_id":"wR","tab_id":"wR:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"}],
         "layouts":[{"workspace_id":"wF","tab_id":"wF:t1","zoomed":false,"area":{"x":0,"y":0,"width":80,"height":24},"focused_pane_id":"wF:p1","panes":[{"pane_id":"wF:p1","focused":true,"rect":{"x":0,"y":0,"width":80,"height":24}}],"splits":[]}]}
        """#
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    func testFlockOwnedWorkspacesAndEverythingInThemAreGone() {
        let visible = model(focusedWorkspace: "w1", focusedTab: "w1:t1", focusedPane: "w1:p1").withoutFlockOwned

        XCTAssertEqual(visible.workspaces.map(\.workspaceID), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(Set(visible.tabs.keys), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(Set(visible.panes.keys), [PaneID(rawValue: "w1:p1")])
        XCTAssertTrue(visible.layouts.isEmpty)
        XCTAssertEqual(visible.focusedTabID, TabID(rawValue: "w1:t1"))
    }

    /// herdr's focus inside a hidden workspace reads as no focus at all, so
    /// nothing that follows focus can follow it there.
    func testFocusInsideAFlockOwnedWorkspaceReadsAsNone() {
        let visible = model(focusedWorkspace: "wR", focusedTab: "wR:t1", focusedPane: "wR:p1").withoutFlockOwned

        XCTAssertNil(visible.focusedWorkspaceID)
        XCTAssertNil(visible.focusedTabID)
        XCTAssertNil(visible.focusedPaneID)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run `xcodegen`, then `RtLabelsTests` and `VisibleSessionTests`. Expected: compile failure, `cannot find 'RtLabels' in scope`.

- [ ] **Step 3: Implement**

`Sources/FlockCore/Rt/RtLabels.swift`:

```swift
import Foundation

public enum RtKind: String, Sendable, CaseIterable {
    case nav, glitter, run, runner
}

/// How flock marks what it owns in herdr. The workspace label is the whole
/// test for "hidden from every surface"; a tab label links the tab to the pane
/// that opened it, by that pane's terminal, and names its files by token.
public enum RtLabels {
    public static let sharedWorkspace = "flock:rt"
    public static let runnerWorkspacePrefix = "flock:rt runner "

    public static func isFlockOwned(workspaceLabel label: String) -> Bool {
        label == sharedWorkspace || label.hasPrefix(runnerWorkspacePrefix)
    }

    public static func runnerWorkspaceLabel(linkedTo terminal: TerminalID) -> String {
        runnerWorkspacePrefix + terminal.rawValue
    }

    public struct TabLink: Equatable, Sendable {
        public let kind: RtKind
        public let terminal: TerminalID
        public let token: String

        public init(kind: RtKind, terminal: TerminalID, token: String) {
            self.kind = kind
            self.terminal = terminal
            self.token = token
        }
    }

    public static func tabLabel(_ link: TabLink) -> String {
        "\(link.kind.rawValue) \(link.terminal.rawValue) \(link.token)"
    }

    public static func tabLink(fromLabel label: String) -> TabLink? {
        let parts = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = RtKind(rawValue: parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return TabLink(kind: kind, terminal: TerminalID(rawValue: parts[1]), token: parts[2])
    }
}
```

`Sources/FlockCore/Rt/VisibleSession.swift`:

```swift
import Foundation

extension SessionModel {
    /// The session without flock's own workspaces, which is the model every
    /// view reads: filtered once here, no surface can show them. Focus that
    /// sits inside one reads as none, so nothing that follows herdr's focus
    /// can follow it there.
    public var withoutFlockOwned: SessionModel {
        let hidden = Set(workspaces.filter { RtLabels.isFlockOwned(workspaceLabel: $0.label) }.map(\.workspaceID))
        guard !hidden.isEmpty else { return self }
        var visible = self
        let hiddenTabs = Set(hidden.flatMap { tabs[$0] ?? [] }.map(\.tabID))
        visible.workspaces.removeAll { hidden.contains($0.workspaceID) }
        for workspace in hidden { visible.tabs.removeValue(forKey: workspace) }
        visible.panes = panes.filter { !hidden.contains($0.value.workspaceID) }
        visible.layouts = layouts.filter { !hidden.contains($0.value.workspaceID) }
        if let workspace = focusedWorkspaceID, hidden.contains(workspace) {
            visible.focusedWorkspaceID = nil
        }
        if let tab = focusedTabID, hiddenTabs.contains(tab) {
            visible.focusedTabID = nil
        }
        if let pane = focusedPaneID, let record = panes[pane], hidden.contains(record.workspaceID) {
            visible.focusedPaneID = nil
        }
        return visible
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Expected: `RtLabelsTests` 4/4, `VisibleSessionTests` 2/2.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: label flock's own workspaces and tabs, and a model without them

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: SessionViewModel keeps the full model and shows the visible one

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`update(model:connection:)` at ~179, `reconcileClosedPanes` at ~360, `refreshLayoutExports` at ~389, `perform(subject:target:board:)` at ~1105)
- Modify: `Sources/FlockCore/Rail/RailSections.swift:27` (`isRailRow`)
- Modify: `Tests/FlockCoreTests/SessionViewModelTests.swift`, `Tests/FlockCoreTests/RailSectionsTests.swift`

**Interfaces:**
- Consumes: `SessionModel.withoutFlockOwned`, `RtLabels.isFlockOwned` (Task 2).
- Produces: `public private(set) var fullModel: SessionModel?` on `SessionViewModel`; `model` is now always `fullModel?.withoutFlockOwned`. Drags plan against `fullModel`, because herdr's `workspace.move` takes an index into its full list and herdr appends new workspaces, so a flock-owned one soon sits between visible ones.

- [ ] **Step 1: Write the failing tests**

Add a builder beside the other `makeModel...` helpers in `SessionViewModelTests.swift`:

```swift
/// `w1` (the one visible workspace, `w1:p1` in `w1:t1`) plus `wF`, a flock
/// owned workspace whose tab `wF:t1` holds `wF:p1`.
private func makeModelWithFlockWorkspace(
    focusedWorkspaceID: String = "w1", focusedTabID: String = "w1:t1", focusedPaneID: String = "w1:p1",
    includingFlockPane: Bool = true
) -> SessionModel {
    let flockPane = includingFlockPane
        ? #",{"pane_id":"wF:p1","terminal_id":"term_f1","workspace_id":"wF","tab_id":"wF:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"}"#
        : ""
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspaceID)","focused_tab_id":"\#(focusedTabID)","focused_pane_id":"\#(focusedPaneID)",
     "workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},
                   {"workspace_id":"wF","label":"flock:rt","number":2,"active_tab_id":"wF:t1","agent_status":"unknown"}],
     "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"orig","number":1,"pane_count":1,"agent_status":"unknown"},
             {"tab_id":"wF:t1","workspace_id":"wF","label":"nav term_a1 tok1","number":1,"pane_count":1,"agent_status":"unknown"}],
     "panes":[{"pane_id":"w1:p1","terminal_id":"term_a1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}\#(flockPane)],
     "layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
}
```

Add to `SessionViewModelTests`:

```swift
    // MARK: - flock-owned workspaces

    @MainActor
    func testFlockOwnedWorkspacesStayInTheFullModelOnly() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)

        XCTAssertEqual(viewModel.model?.workspaces.map(\.workspaceID), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(viewModel.fullModel?.workspaces.count, 2)
    }

    @MainActor
    func testHerdrFocusLandingInAFlockOwnedTabLeavesTheSelectionAlone() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))

        viewModel.update(
            model: makeModelWithFlockWorkspace(focusedWorkspaceID: "wF", focusedTabID: "wF:t1", focusedPaneID: "wF:p1"),
            connection: .live
        )

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
    }

    /// A hidden pane's surface lives in the modal, not the canvas, and has to
    /// be torn down when herdr closes it like any other.
    @MainActor
    func testAHiddenPaneThatClosesIsTornDown() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)
        _ = await viewModel.attachPane(PaneID(rawValue: "wF:p1"))

        viewModel.update(model: makeModelWithFlockWorkspace(includingFlockPane: false), connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(factory.surfaces[PaneID(rawValue: "wF:p1")]?.detachCallCount, 1)
    }
```

Add to `RailSectionsTests`, beside the reorder-index tests (it uses that file's `model(_:)` helper):

```swift
    /// flock's own workspaces sit in herdr's order too, and herdr appends new
    /// ones, so one soon lands between visible rows. A slot has to map past it.
    func testFlocksOwnWorkspacesAreNotRailRows() {
        let full = model(["acme", "notes", "flock:rt", "deck", "flock:rt runner term_a1"])
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: full, board: nil), 3)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 3, in: full, board: nil), 4)
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run `SessionViewModelTests` and `RailSectionsTests`. Expected: compile failure on `fullModel`; with a stub property added, the focus test fails with the selection moved to `wF:t1`, and `testFlocksOwnWorkspacesAreNotRailRows` fails with 2 for the first assertion. The teardown test passes before the change: it pins that the filtering below must not stop hidden panes being torn down (it fails if `reconcileClosedPanes` reads the filtered model).

- [ ] **Step 3: Implement**

In `SessionViewModel`, beside `model`:

```swift
    /// Everything herdr reports, flock's own workspaces included. The rt
    /// coordinator, surface teardown, layout exports and drag planning read
    /// it (herdr's indexes are into its full lists); every view reads
    /// `model`, which never holds a flock-owned workspace.
    public private(set) var fullModel: SessionModel?
```

Change the head of `update`:

```swift
    public func update(model newFullModel: SessionModel?, connection: ConnectionState) {
        fullModel = newFullModel
        let model = newFullModel?.withoutFlockOwned
        let previousFocusedTabID = self.model?.focusedTabID
        let previousModel = self.model
        self.model = model
```

(the rest of the body is unchanged and keeps reading the local `model`).

In `reconcileClosedPanes`, read the full model:

```swift
        let known = Set((fullModel?.panes ?? [:]).keys)
```

In `refreshLayoutExports`, read the full model so a hidden tab's split tree is fetched for the modal:

```swift
        guard let layoutExportCoordinator, let model = fullModel else { return }
```

In `perform(subject:target:board:)`, both branches plan against the full model (the `guard let model` in the no-journal branch and the `let model = self.model` inside `runExclusively`):

```swift
            guard let model = fullModel, let planExecutor else { return .notAttempted }
```

```swift
            guard let self, let model = self.fullModel, let planExecutor = self.planExecutor else { return }
```

and in the comment above the second one, "Reads `model` fresh" becomes "Reads `fullModel` fresh".

In `RailSections.isRailRow`, a flock-owned workspace is never a rail row:

```swift
    public static func isRailRow(label: String, board: BoardWorkspaceNames?) -> Bool {
        !HerdWorkspace.isHerd(label: label) && !(board?.contains(label: label) ?? false)
            && !RtLabels.isFlockOwned(workspaceLabel: label)
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run `SessionViewModelTests`, then the whole `FlockCoreTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "session: views read a model without flock's own workspaces

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Typed lines, result files, and the foreground snapshot

**Files:**
- Create: `Sources/FlockCore/Rt/RtCommandLine.swift`
- Create: `Sources/FlockCore/Rt/RtFiles.swift`
- Modify: `Sources/FlockCore/Herdr/PaneForegroundJob.swift`
- Create: `Tests/FlockCoreTests/RtCommandLineTests.swift`, `Tests/FlockCoreTests/RtFilesTests.swift`
- Modify: `Tests/FlockCoreTests/PaneForegroundJobTests.swift`

**Interfaces:**
- Consumes: `RtKind` (Task 2).
- Produces:
  - `public enum ShellFlavor { case posix, fish; init(processName: String?) }`
  - `public enum RtCommandLine` with `quoted(_:) -> String`, `command(for: RtKind, shell: ShellFlavor) -> String`, `phaseTwo(_ result: RunResolveResult, shell:) -> String`, `cd(_ path: String) -> String`
  - `public struct RunResolveResult: Decodable, Equatable, Sendable` (`targetDir`, `packageLabel`, `worktree`, `branch`, `commandTemplate`, `script`)
  - `public struct RtFilePaths { out: URL; status: URL; init(token:directory:) }`
  - `public protocol RtFileStore: Sendable { read(_:) -> String?; delete(_:); prepareDirectory(_:) }`, `public struct DiskRtFileStore: RtFileStore`
  - `public enum RtFileParse { status(_ text: String?) -> Int32?; runResult(_ text: String?) -> RunResolveResult? }`
  - `PaneForegroundJob.Snapshot { busy: Bool; shellName: String?; foregroundNames: [String] }` and `PaneForegroundJob.snapshot(processInfoResponse:) -> Snapshot?`

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtCommandLineTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class RtCommandLineTests: XCTestCase {
    func testEachKindsLineCarriesItsRedirectAndTheStatusSuffix() {
        XCTAssertEqual(RtCommandLine.command(for: .nav, shell: .posix), #"command rt nav >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .glitter, shell: .posix), #"command rt glitter; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .run, shell: .posix), #"command rt run --resolve-only >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .runner, shell: .posix), #"command rt runner --herdr; echo $? >"$FLOCK_RT_STATUS""#)
    }

    func testAFishShellGetsItsStatusVariable() {
        XCTAssertEqual(RtCommandLine.command(for: .glitter, shell: .fish), #"command rt glitter; echo $status >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(ShellFlavor(processName: "fish"), .fish)
        XCTAssertEqual(ShellFlavor(processName: "-fish"), .fish)
        XCTAssertEqual(ShellFlavor(processName: "zsh"), .posix)
        XCTAssertEqual(ShellFlavor(processName: nil), .posix)
    }

    func testPhaseTwoCdsIntoTheTargetThenRunsTheTemplate() {
        let result = RunResolveResult(targetDir: "/src/acme/web", packageLabel: "web", worktree: "/src/acme", branch: "main", commandTemplate: "pnpm run test", script: "test")
        XCTAssertEqual(RtCommandLine.phaseTwo(result, shell: .posix), #"cd '/src/acme/web' && pnpm run test; echo $? >"$FLOCK_RT_STATUS""#)
    }

    func testQuotingSurvivesASingleQuote() {
        XCTAssertEqual(RtCommandLine.quoted("/src/matt's app"), #"'/src/matt'\''s app'"#)
        XCTAssertEqual(RtCommandLine.cd("/src/matt's app"), #"cd '/src/matt'\''s app'"#)
    }
}
```

`Tests/FlockCoreTests/RtFilesTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class RtFilesTests: XCTestCase {
    func testPathsAreNamedByToken() {
        let paths = RtFilePaths(token: "3f2a", directory: URL(fileURLWithPath: "/tmp/flock-rt", isDirectory: true))
        XCTAssertEqual(paths.out.path, "/tmp/flock-rt/3f2a.out")
        XCTAssertEqual(paths.status.path, "/tmp/flock-rt/3f2a.status")
    }

    func testAStatusFileReadsAsItsNumber() {
        XCTAssertEqual(RtFileParse.status("0\n"), 0)
        XCTAssertEqual(RtFileParse.status("130"), 130)
        XCTAssertNil(RtFileParse.status(""))
        XCTAssertNil(RtFileParse.status(nil))
    }

    /// `rt run --resolve-only` prints the result as one JSON line.
    func testARunResultReadsAsJSONAndAnythingElseAsNone() {
        let line = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"# + "\n"
        XCTAssertEqual(RtFileParse.runResult(line)?.commandTemplate, "pnpm run test")
        XCTAssertNil(RtFileParse.runResult(""))
        XCTAssertNil(RtFileParse.runResult("/src/acme/web\n"))
        XCTAssertNil(RtFileParse.runResult(nil))
    }

    func testTheDiskStoreReadsDeletesAndMakesItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskRtFileStore()
        store.prepareDirectory(directory)
        let url = directory.appendingPathComponent("a.status")
        try "0\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.read(url), "0\n")
        store.delete(url)
        XCTAssertNil(store.read(url))
    }
}
```

Append to `PaneForegroundJobTests`:

```swift
    func testTheSnapshotNamesTheShellAndWhatElseHoldsTheForeground() throws {
        let idle = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"fish","pid":500}]}}}"#.utf8)
        let busy = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731,"foreground_processes":[{"name":"bun","pid":731},{"name":"rt-ui","pid":740}]}}}"#.utf8)

        let idleSnapshot = try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: idle))
        XCTAssertFalse(idleSnapshot.busy)
        XCTAssertEqual(idleSnapshot.shellName, "fish")
        XCTAssertEqual(idleSnapshot.foregroundNames, [])

        let busySnapshot = try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: busy))
        XCTAssertTrue(busySnapshot.busy)
        XCTAssertNil(busySnapshot.shellName)
        XCTAssertEqual(busySnapshot.foregroundNames, ["bun", "rt-ui"])
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run `xcodegen`, then the three classes. Expected: compile failure on the new names.

- [ ] **Step 3: Implement**

`Sources/FlockCore/Rt/RtCommandLine.swift`:

```swift
import Foundation

public enum ShellFlavor: Equatable, Sendable {
    case posix, fish

    /// A login shell's name carries a leading `-` (`-zsh`).
    public init(processName: String?) {
        let name = (processName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        self = name.hasSuffix("fish") ? .fish : .posix
    }

    var statusVariable: String {
        switch self {
        case .posix: "$?"
        case .fish: "$status"
        }
    }
}

/// The lines flock types into a hidden rt pane. `command` skips a user's
/// `rt()` shell function, so a result lands in the file rather than in a `cd`;
/// the suffix records the exit status, the one signal that separates a clean
/// quit from an error.
public enum RtCommandLine {
    /// Single quotes, with an embedded quote closed, escaped and reopened. The
    /// same spelling works in POSIX shells and fish.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func command(for kind: RtKind, shell: ShellFlavor) -> String {
        let body: String
        switch kind {
        case .nav: body = #"command rt nav >"$FLOCK_RT_OUT""#
        case .glitter: body = "command rt glitter"
        case .run: body = #"command rt run --resolve-only >"$FLOCK_RT_OUT""#
        case .runner: body = "command rt runner --herdr"
        }
        return body + statusSuffix(shell)
    }

    public static func phaseTwo(_ result: RunResolveResult, shell: ShellFlavor) -> String {
        "cd \(quoted(result.targetDir)) && \(result.commandTemplate)" + statusSuffix(shell)
    }

    public static func cd(_ path: String) -> String {
        "cd \(quoted(path))"
    }

    private static func statusSuffix(_ shell: ShellFlavor) -> String {
        #"; echo \#(shell.statusVariable) >"$FLOCK_RT_STATUS""#
    }
}
```

`Sources/FlockCore/Rt/RtFiles.swift`:

```swift
import Foundation

/// `rt run --resolve-only`'s printed result (`RunResolveResult` in rt's
/// `commands/run.ts`).
public struct RunResolveResult: Decodable, Equatable, Sendable {
    public let targetDir: String
    public let packageLabel: String
    public let worktree: String
    public let branch: String
    public let commandTemplate: String
    public let script: String

    public init(targetDir: String, packageLabel: String, worktree: String, branch: String, commandTemplate: String, script: String) {
        self.targetDir = targetDir
        self.packageLabel = packageLabel
        self.worktree = worktree
        self.branch = branch
        self.commandTemplate = commandTemplate
        self.script = script
    }
}

/// The two files one rt item's typed lines write, named by the item's token.
/// Their paths reach the pane through the env its tab was created with.
public struct RtFilePaths: Equatable, Sendable {
    public let out: URL
    public let status: URL

    public init(token: String, directory: URL) {
        out = directory.appendingPathComponent("\(token).out")
        status = directory.appendingPathComponent("\(token).status")
    }
}

public protocol RtFileStore: Sendable {
    func read(_ url: URL) -> String?
    func delete(_ url: URL)
    func prepareDirectory(_ url: URL)
}

public struct DiskRtFileStore: RtFileStore {
    public init() {}

    public func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    public func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func prepareDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public enum RtFileParse {
    public static func status(_ text: String?) -> Int32? {
        text.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func runResult(_ text: String?) -> RunResolveResult? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(RunResolveResult.self, from: Data(trimmed.utf8))
    }
}
```

In `PaneForegroundJob.swift`, add the snapshot and route `isBusy` through it:

```swift
    public struct Snapshot: Equatable, Sendable {
        public let busy: Bool
        /// The shell's own process name while it is in the foreground list,
        /// which is only while it sits at its prompt.
        public let shellName: String?
        /// Everything but the shell that holds the foreground.
        public let foregroundNames: [String]
    }

    public static func snapshot(processInfoResponse data: Data) -> Snapshot? {
        guard let info = try? JSONDecoder().decode(Envelope.self, from: data).result.processInfo,
              let shellPID = info.shellPID
        else { return nil }
        let processes = info.foregroundProcesses ?? []
        let busy: Bool
        if !processes.isEmpty {
            busy = processes.contains { $0.pid != shellPID }
        } else if let group = info.foregroundProcessGroupID {
            busy = group != shellPID
        } else {
            return nil
        }
        return Snapshot(
            busy: busy,
            shellName: processes.first { $0.pid == shellPID }?.name,
            foregroundNames: processes.filter { $0.pid != shellPID }.compactMap(\.name)
        )
    }

    public static func isBusy(processInfoResponse data: Data) -> Bool? {
        snapshot(processInfoResponse: data)?.busy
    }
```

and give the private `Process` decoder a name: `struct Process: Decodable { let pid: Int; let name: String? }`. Delete the old body of `isBusy`.

- [ ] **Step 4: Run the tests to see them pass**

Expected: `RtCommandLineTests` 4/4, `RtFilesTests` 4/4, `PaneForegroundJobTests` 6/6.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: typed lines, the result and status files, and a foreground snapshot

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: One command's lifecycle

**Files:**
- Create: `Sources/FlockCore/Rt/RtLifecycle.swift`
- Create: `Tests/FlockCoreTests/RtLifecycleTests.swift`

**Interfaces:**
- Consumes: `RtKind`, `RunResolveResult`, `RtFileParse` (Tasks 2, 4).
- Produces:
  - `public struct RtLifecycle: Equatable, Sendable` with `static let startCeiling: TimeInterval = 3`, `enum Stage { running, picking, script, selfLaunched, done }`, `struct Observation { firstPaneBusy, anyPaneBusy, statusExists: Bool; status: Int32?; out: String?; now: Date }`, `enum Outcome { watching, typePhaseTwo(RunResolveResult), closeTab, cdLinkedPane(String), exited(Int32?), finished(Int32?), runnerEnded }`, `init(kind:startedAt:)`, `static func resumed(kind:stage:at:) -> RtLifecycle`, `var stage: Stage { get }`, `mutating func observe(_:) -> Outcome`, `mutating func phaseTwoTyped(at:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtLifecycleTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class RtLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let resultLine = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#

    private func seen(busy: Bool, first: Bool? = nil, status: Int32? = nil, statusExists: Bool = false, out: String? = nil, at seconds: TimeInterval) -> RtLifecycle.Observation {
        RtLifecycle.Observation(
            firstPaneBusy: first ?? busy, anyPaneBusy: busy, statusExists: statusExists || status != nil,
            status: status, out: out, now: start.addingTimeInterval(seconds)
        )
    }

    func testNavQuittingCleanlyClosesItsTab() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: true, at: 0.3)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, out: "", at: 5)), .closeTab)
        XCTAssertEqual(life.stage, .done)
    }

    func testNavCdHereCarriesTheFolder() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, out: "/src/acme/web\n", at: 5)), .cdLinkedPane("/src/acme/web"))
    }

    func testCancelledIsClean() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 130, at: 5)), .closeTab)
    }

    func testAnUncleanExitShowsItsStatus() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 5)), .exited(1))
    }

    /// rt exits before the shell writes the status; the gap is not the end.
    func testIdleWithoutAStatusAfterRunningIsStillWatching() {
        var life = RtLifecycle(kind: .nav, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5)), .watching)
    }

    func testACommandNeverSeenRunningEndsAtTheCeilingAsUnclean() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: false, at: 1)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, at: RtLifecycle.startCeiling + 0.1)), .exited(nil))
    }

    func testAFastCommandWithAStatusEndsWithoutEverBeingSeen() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 0.3)), .exited(1))
    }

    func testTheRunnerQuittingEndsIt() {
        var life = RtLifecycle(kind: .runner, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 60)), .runnerEnded)
    }

    func testRunPhaseOneWithAResultAsksForPhaseTwo() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        XCTAssertEqual(life.stage, .picking)
        _ = life.observe(seen(busy: true, at: 0.3))
        let outcome = life.observe(seen(busy: false, status: 0, out: resultLine, at: 4))
        XCTAssertEqual(outcome, .typePhaseTwo(RtFileParse.runResult(resultLine)!))

        life.phaseTwoTyped(at: start.addingTimeInterval(4.1))
        XCTAssertEqual(life.stage, .script)
        XCTAssertEqual(life.observe(seen(busy: true, at: 4.4)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 2, at: 9)), .finished(2))
    }

    /// Phase 1 ends on rt's own pane only; a split "Launch all" made is still busy.
    func testPhaseOneEndsOnTheFirstPaneAlone() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: true, first: false, status: 0, at: 4)), .watching)
        XCTAssertEqual(life.stage, .selfLaunched)
    }

    func testASelfLaunchFinishesWithoutAStatusOnceItsPanesGoQuiet() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, at: 4))
        XCTAssertEqual(life.stage, .selfLaunched)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 4.3)), .watching, "the script rt typed has not started yet")
        XCTAssertEqual(life.observe(seen(busy: true, at: 4.6)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 30)), .finished(nil))
    }

    func testASelfLaunchNeverSeenRunningFinishesAtTheCeiling() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, at: 4))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 4 + RtLifecycle.startCeiling + 0.1)), .finished(nil))
    }

    func testRunPhaseOneWithNoResultAndAFailureIsACancel() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 1, at: 4)), .closeTab)
    }

    func testAResumedItemCarriesOnFromItsStage() {
        var life = RtLifecycle.resumed(kind: .run, stage: .script, at: start)
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, at: 0.3)), .finished(0))
    }

    /// ctrl+c on the script: the shell skips the status write.
    func testAScriptStoppedWithoutAStatusFinishesAfterTheGrace() {
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, status: 0, out: resultLine, at: 4))
        life.phaseTwoTyped(at: start.addingTimeInterval(4.1))
        _ = life.observe(seen(busy: true, at: 4.4))

        XCTAssertEqual(life.observe(seen(busy: false, at: 60)), .watching, "the grace starts at the first idle poll")
        XCTAssertEqual(life.observe(seen(busy: false, at: 60 + RtLifecycle.startCeiling + 0.1)), .finished(nil))
    }

    func testACommandKilledWithoutAStatusExitsAfterTheGrace() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5)), .watching)
        XCTAssertEqual(life.observe(seen(busy: false, at: 5 + RtLifecycle.startCeiling + 0.1)), .exited(nil))
    }

    func testBusyAgainRestartsTheGrace() {
        var life = RtLifecycle(kind: .glitter, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        _ = life.observe(seen(busy: false, at: 5))
        _ = life.observe(seen(busy: true, at: 6))
        XCTAssertEqual(life.observe(seen(busy: false, at: 5 + RtLifecycle.startCeiling + 0.1)), .watching)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile failure, `cannot find 'RtLifecycle'`.

- [ ] **Step 3: Implement**

`Sources/FlockCore/Rt/RtLifecycle.swift`:

```swift
import Foundation

/// One rt command's life in its hidden tab, told by polls: whether anything
/// but the shell holds a foreground, and what the status and result files
/// hold. Pure, so every rule below is pinned by a test without a herdr.
///
/// `run` has two phases so the picker's end and the script's start are never
/// confused: the moment between rt exiting and the script starting reads as
/// idle, and nothing but the phase says which it is.
public struct RtLifecycle: Equatable, Sendable {
    /// How long an idle pane still means the command has yet to start. Past
    /// it, a command never seen running has already finished.
    public static let startCeiling: TimeInterval = 3

    public enum Stage: Equatable, Sendable {
        case running, picking, script, selfLaunched, done
    }

    public struct Observation: Equatable, Sendable {
        public var firstPaneBusy: Bool
        public var anyPaneBusy: Bool
        public var statusExists: Bool
        public var status: Int32?
        public var out: String?
        public var now: Date

        public init(firstPaneBusy: Bool, anyPaneBusy: Bool, statusExists: Bool, status: Int32?, out: String?, now: Date) {
            self.firstPaneBusy = firstPaneBusy
            self.anyPaneBusy = anyPaneBusy
            self.statusExists = statusExists
            self.status = status
            self.out = out
            self.now = now
        }
    }

    public enum Outcome: Equatable, Sendable {
        case watching
        case typePhaseTwo(RunResolveResult)
        case closeTab
        case cdLinkedPane(String)
        case exited(Int32?)
        case finished(Int32?)
        case runnerEnded
    }

    public let kind: RtKind
    public private(set) var stage: Stage
    private var startedAt: Date
    private var seenBusy = false
    private var idleSince: Date?

    public init(kind: RtKind, startedAt: Date) {
        self.kind = kind
        self.stage = kind == .run ? .picking : .running
        self.startedAt = startedAt
    }

    public static func resumed(kind: RtKind, stage: Stage, at time: Date) -> RtLifecycle {
        var lifecycle = RtLifecycle(kind: kind, startedAt: time)
        lifecycle.stage = stage
        return lifecycle
    }

    public mutating func phaseTwoTyped(at time: Date) {
        stage = .script
        startedAt = time
        seenBusy = false
        idleSince = nil
    }

    public mutating func observe(_ seen: Observation) -> Outcome {
        if seen.anyPaneBusy {
            seenBusy = true
            idleSince = nil
        }
        switch stage {
        case .done:
            return .watching
        case .running:
            guard !seen.anyPaneBusy else { return .watching }
            if ended(seen) {
                stage = .done
                return singlePhaseOutcome(seen)
            }
            guard stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .exited(nil)
        case .picking:
            return pickingOutcome(seen)
        case .script:
            guard !seen.anyPaneBusy else { return .watching }
            guard ended(seen) || stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .finished(seen.statusExists ? seen.status : nil)
        case .selfLaunched:
            guard !seen.anyPaneBusy, seenBusy || pastCeiling(seen) else { return .watching }
            stage = .done
            return .finished(nil)
        }
    }

    private mutating func pickingOutcome(_ seen: Observation) -> Outcome {
        guard !seen.firstPaneBusy else { return .watching }
        guard seen.statusExists else {
            if !seenBusy, pastCeiling(seen) {
                stage = .done
                return .exited(nil)
            }
            guard stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .closeTab
        }
        if let result = RtFileParse.runResult(seen.out) {
            return .typePhaseTwo(result)
        }
        if seen.status == 0 {
            stage = .selfLaunched
            startedAt = seen.now
            seenBusy = false
            return .watching
        }
        stage = .done
        return .closeTab
    }

    private func ended(_ seen: Observation) -> Bool {
        seen.statusExists || (!seenBusy && pastCeiling(seen))
    }

    /// A job killed by a signal (ctrl+c on a dev server) makes zsh and bash
    /// skip the rest of its `;` list, so the status is never written. Idle
    /// this long after running, with no status, means it ended that way.
    private mutating func stoppedWithoutStatus(_ seen: Observation) -> Bool {
        guard seenBusy else { return false }
        let since = idleSince ?? seen.now
        idleSince = since
        return seen.now.timeIntervalSince(since) >= Self.startCeiling
    }

    private func pastCeiling(_ seen: Observation) -> Bool {
        seen.now.timeIntervalSince(startedAt) >= Self.startCeiling
    }

    private func singlePhaseOutcome(_ seen: Observation) -> Outcome {
        guard seen.statusExists, seen.status == 0 || seen.status == 130 else {
            return .exited(seen.statusExists ? seen.status : nil)
        }
        switch kind {
        case .nav:
            let path = seen.out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .closeTab : .cdLinkedPane(path)
        case .glitter, .run:
            return .closeTab
        case .runner:
            return .runnerEnded
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Expected: `RtLifecycleTests` 17/17.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: one command's lifecycle as a pure state machine

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The herdr verbs

**Files:**
- Create: `Sources/FlockCore/Rt/RtHerdr.swift`
- Create: `Tests/FlockCoreTests/RtHerdrTests.swift`

**Interfaces:**
- Consumes: `HerdrCommandClient`, `JSONValue`, `PaneForegroundJob.snapshot` (Task 4).
- Produces: `public struct RtHerdr: Sendable` with `init(client:)`, `struct Created { workspaceID; tabID; rootPaneID }`, `createWorkspace(label:cwd:env:) async throws -> Created`, `createTab(in:label:cwd:env:) async throws -> Created`, `renameTab(_:to:) async throws`, `type(_:into:) async throws`, `sendKeys(_:to:) async throws`, `paneState(_:) async -> PaneForegroundJob.Snapshot?`, `closeTab(_:) async throws`, `closeWorkspace(_:) async throws`, `focus(_:) async throws`, `split(_:cwd:) async throws`, `static func describe(_ error: Error) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtHerdrTests.swift`:

```swift
import XCTest
@testable import FlockCore

private actor RecordingRtClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    let answers: [String: String]

    init(answers: [String: String] = [:]) {
        self.answers = answers
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data((answers[method] ?? "{}").utf8)
    }
}

private func string(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    return nil
}

private func bool(_ value: JSONValue?) -> Bool? {
    if case .bool(let flag) = value { return flag }
    return nil
}

final class RtHerdrTests: XCTestCase {
    private let created = #"{"result":{"type":"tab_created","tab":{"tab_id":"wF:t2","workspace_id":"wF"},"root_pane":{"pane_id":"wF:p2","terminal_id":"term_f2"}}}"#

    func testATabIsCreatedHiddenLabelledAndCarryingItsEnv() async throws {
        let client = RecordingRtClient(answers: ["tab.create": created])
        let herdr = RtHerdr(client: client)

        let made = try await herdr.createTab(
            in: WorkspaceID(rawValue: "wF"), label: "nav term_a1 tok1", cwd: "/src/acme",
            env: ["FLOCK_RT_OUT": "/tmp/flock-rt/tok1.out"]
        )

        XCTAssertEqual(made, RtHerdr.Created(workspaceID: WorkspaceID(rawValue: "wF"), tabID: TabID(rawValue: "wF:t2"), rootPaneID: PaneID(rawValue: "wF:p2")))
        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "tab.create")
        XCTAssertEqual(string(call.params["label"]), "nav term_a1 tok1")
        XCTAssertEqual(string(call.params["cwd"]), "/src/acme")
        XCTAssertEqual(bool(call.params["focus"]), false)
        guard case .object(let env) = call.params["env"] else { return XCTFail("no env") }
        XCTAssertEqual(string(env["FLOCK_RT_OUT"]), "/tmp/flock-rt/tok1.out")
    }

    func testAnAnswerWithoutTheCreatedIdsThrows() async {
        let herdr = RtHerdr(client: RecordingRtClient(answers: ["workspace.create": "{}"]))
        do {
            _ = try await herdr.createWorkspace(label: "flock:rt", cwd: "/src/acme", env: [:])
            XCTFail("expected a throw")
        } catch {}
    }

    func testTypingSubmitsWithAnEnterKey() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).type("command rt glitter", into: PaneID(rawValue: "wF:p2"))

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.send_input")
        XCTAssertEqual(string(call.params["text"]), "command rt glitter")
        guard case .array(let keys) = call.params["keys"] else { return XCTFail("no keys") }
        XCTAssertEqual(keys.compactMap(string), ["Enter"])
    }

    func testKeysGoAsKeysNeverText() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).sendKeys(["y"], to: PaneID(rawValue: "wR:p1"))

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.send_keys")
        guard case .array(let keys) = call.params["keys"] else { return XCTFail("no keys") }
        XCTAssertEqual(keys.compactMap(string), ["y"])
    }

    func testAPaneStateComesFromProcessInfo() async {
        let answer = #"{"result":{"process_info":{"pane_id":"wF:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500}]}}}"#
        let herdr = RtHerdr(client: RecordingRtClient(answers: ["pane.process_info": answer]))
        let state = await herdr.paneState(PaneID(rawValue: "wF:p2"))
        XCTAssertEqual(state?.busy, false)
        XCTAssertEqual(state?.shellName, "zsh")
    }

    func testASplitOpensRightAtTheFolderAndTakesFocus() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).split(PaneID(rawValue: "w1:p1"), cwd: "/src/acme/web")

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.split")
        XCTAssertEqual(string(call.params["target_pane_id"]), "w1:p1")
        XCTAssertEqual(string(call.params["direction"]), "right")
        XCTAssertEqual(string(call.params["cwd"]), "/src/acme/web")
        XCTAssertEqual(bool(call.params["focus"]), true)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile failure, `cannot find 'RtHerdr'`.

- [ ] **Step 3: Implement**

`Sources/FlockCore/Rt/RtHerdr.swift`:

```swift
import Foundation

/// The herdr verbs rt's hidden terminals use, with their wire shapes in one
/// place. Everything is created unfocused: herdr's focus moving into a hidden
/// workspace would take the canvas with it.
public struct RtHerdr: Sendable {
    public struct Created: Equatable, Sendable {
        public let workspaceID: WorkspaceID
        public let tabID: TabID
        public let rootPaneID: PaneID

        public init(workspaceID: WorkspaceID, tabID: TabID, rootPaneID: PaneID) {
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.rootPaneID = rootPaneID
        }
    }

    struct Unreadable: Error {}

    let client: any HerdrCommandClient

    public init(client: any HerdrCommandClient) {
        self.client = client
    }

    public func createWorkspace(label: String, cwd: String, env: [String: String]) async throws -> Created {
        try Self.created(from: await client.requestRaw("workspace.create", [
            "label": .string(label), "cwd": .string(cwd), "focus": .bool(false), "env": Self.object(env),
        ]))
    }

    public func createTab(in workspace: WorkspaceID, label: String, cwd: String, env: [String: String]) async throws -> Created {
        try Self.created(from: await client.requestRaw("tab.create", [
            "workspace_id": .string(workspace.rawValue), "label": .string(label), "cwd": .string(cwd),
            "focus": .bool(false), "env": Self.object(env),
        ]))
    }

    public func renameTab(_ tab: TabID, to label: String) async throws {
        _ = try await client.requestRaw("tab.rename", ["tab_id": .string(tab.rawValue), "label": .string(label)])
    }

    /// The Enter rides `keys`: herdr pastes `text` inside a bracketed paste
    /// whenever the program enabled one, and a newline there is not a submit.
    public func type(_ line: String, into pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.send_input", [
            "pane_id": .string(pane.rawValue), "text": .string(line), "keys": .array([.string("Enter")]),
        ])
    }

    /// Keys, never text: a `y` sent as text reaches a program with bracketed
    /// paste on as a paste, which a confirm does not read as a keypress.
    public func sendKeys(_ keys: [String], to pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.send_keys", [
            "pane_id": .string(pane.rawValue), "keys": .array(keys.map(JSONValue.string)),
        ])
    }

    public func paneState(_ pane: PaneID) async -> PaneForegroundJob.Snapshot? {
        guard let data = try? await client.requestRaw("pane.process_info", ["pane_id": .string(pane.rawValue)]) else {
            return nil
        }
        return PaneForegroundJob.snapshot(processInfoResponse: data)
    }

    public func closeTab(_ tab: TabID) async throws {
        _ = try await client.requestRaw("tab.close", ["tab_id": .string(tab.rawValue)])
    }

    public func closeWorkspace(_ workspace: WorkspaceID) async throws {
        _ = try await client.requestRaw("workspace.close", ["workspace_id": .string(workspace.rawValue)])
    }

    public func focus(_ pane: PaneID) async throws {
        _ = try await client.requestRaw("pane.focus", ["pane_id": .string(pane.rawValue)])
    }

    public func split(_ pane: PaneID, cwd: String) async throws {
        _ = try await client.requestRaw("pane.split", [
            "target_pane_id": .string(pane.rawValue), "direction": .string("right"),
            "cwd": .string(cwd), "focus": .bool(true),
        ])
    }

    public static func describe(_ error: Error) -> String {
        guard let clientError = error as? HerdrClientError else { return String(describing: error) }
        switch clientError {
        case let .server(code, message): return message.isEmpty ? code : message
        case let .transport(message): return message
        case let .timedOut(method): return "\(method) got no answer from herdr"
        case let .protocolTooOld(found, required): return "protocol \(found), need \(required)"
        }
    }

    private static func object(_ env: [String: String]) -> JSONValue {
        .object(env.mapValues(JSONValue.string))
    }

    private static func created(from data: Data) throws -> Created {
        struct Tab: Decodable {
            let tabID: TabID
            let workspaceID: WorkspaceID
            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
                case workspaceID = "workspace_id"
            }
        }
        struct Pane: Decodable {
            let paneID: PaneID
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
        struct Result: Decodable {
            let tab: Tab
            let rootPane: Pane
            enum CodingKeys: String, CodingKey {
                case tab
                case rootPane = "root_pane"
            }
        }
        struct Envelope: Decodable { let result: Result }
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data).result else { throw Unreadable() }
        return Created(workspaceID: result.tab.workspaceID, tabID: result.tab.tabID, rootPaneID: result.rootPane.paneID)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Expected: `RtHerdrTests` 6/6.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: the herdr verbs hidden terminals use

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Items, the modal, the button, the menu, the modal's keys

**Files:**
- Create: `Sources/FlockCore/Rt/RtItem.swift`
- Create: `Tests/FlockCoreTests/RtItemTests.swift`

**Interfaces:**
- Consumes: `RtKind`, `TerminalID`, ids (Tasks 1-2).
- Produces:
  - `public enum RtStrip { exited(Int32?), finished(Int32?); var text: String }`
  - `public struct RtItem: Identifiable, Equatable, Sendable` (`id`, `kind`, `linked`, `workspaceID`, `tabIDs`, `firstPaneID`, `title`, `folder`, `isRunning`, `strip`; `stateText`; `modalTitle(home:)`)
  - `extension RtKind { var defaultTitle: String }`
  - `public struct RtModal: Equatable, Sendable` (`itemID`, `tabID`, `serviceTabID`, `shownTabID`)
  - `public enum RtButtonModel { enum Appearance { absent, rest, active(count: Int) }; appearance(rtInstalled:runningItems:hasRunner:) }`
  - `public struct RtMenuRow { enum Action { open(RtKind), show(String) }; title; action; startsSection }`, `public enum RtMenuModel { rows(hasRunner:runItems:) -> [RtMenuRow] }`
  - `public enum RtModalKey { enum Decision { close, pass }; decide(characters:command:shift:option:control:stripShown:) }`

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtItemTests.swift`:

```swift
import XCTest
@testable import FlockCore

final class RtItemTests: XCTestCase {
    private func item(kind: RtKind = .run, title: String = "pnpm run test", running: Bool = true, strip: RtStrip? = nil) -> RtItem {
        RtItem(
            id: "tok1", kind: kind, linked: TerminalID(rawValue: "term_a1"), workspaceID: WorkspaceID(rawValue: "wF"),
            tabIDs: [TabID(rawValue: "wF:t1")], firstPaneID: PaneID(rawValue: "wF:p1"),
            title: title, folder: "/Users/acme/src/app", isRunning: running, strip: strip
        )
    }

    func testTheButtonRestsWithNothingRunningAndCountsWhatIs() {
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: false, runningItems: 3, hasRunner: true), .absent)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: false), .rest)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: false), .active(count: 2))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: true), .active(count: 3))
    }

    func testTheMenuOffersTheCommandsThenThePanesItems() {
        let rows = RtMenuModel.rows(hasRunner: false, runItems: [item(), item(title: "pnpm run build", running: false, strip: .finished(0))])
        XCTAssertEqual(rows.map(\.title), [
            "nav · browse files here", "glitter · git status", "run · run a script…", "runner",
            "pnpm run test · running", "pnpm run build · finished",
        ])
        XCTAssertEqual(rows.map(\.startsSection), [false, false, false, false, true, false])
        XCTAssertEqual(rows[4].action, .show("tok1"))
    }

    func testTheRunnerRowShowsAnExistingRunner() {
        let rows = RtMenuModel.rows(hasRunner: true, runItems: [])
        XCTAssertEqual(rows.last?.title, "Show runner")
        XCTAssertEqual(rows.last?.action, .open(.runner))
    }

    func testStripsSayWhatHappened() {
        XCTAssertEqual(RtStrip.exited(1).text, "exited 1 · any key closes")
        XCTAssertEqual(RtStrip.exited(nil).text, "exited · any key closes")
        XCTAssertEqual(RtStrip.finished(0).text, "finished · exit 0 · any key closes")
        XCTAssertEqual(RtStrip.finished(nil).text, "finished · any key closes")
    }

    func testTheModalTitleNamesTheCommandAndAShortFolder() {
        XCTAssertEqual(item(kind: .nav, title: "nav").modalTitle(home: "/Users/acme"), "nav · ~/src/app")
        XCTAssertEqual(item().modalTitle(home: "/Users/acme"), "pnpm run test · ~/src/app")
        XCTAssertEqual(item(kind: .glitter).modalTitle(home: "/Users/other"), "glitter · /Users/acme/src/app")
    }
}

final class RtModalKeyTests: XCTestCase {
    func testCommandWClosesTheModal() {
        XCTAssertEqual(RtModalKey.decide(characters: "w", command: true, shift: false, option: false, control: false, stripShown: false), .close)
    }

    func testOtherCommandsPassEvenWithAStripUp() {
        XCTAssertEqual(RtModalKey.decide(characters: "q", command: true, shift: false, option: false, control: false, stripShown: true), .pass)
        XCTAssertEqual(RtModalKey.decide(characters: "w", command: true, shift: true, option: false, control: false, stripShown: false), .pass)
    }

    func testWithAStripUpAnyPlainKeyCloses() {
        XCTAssertEqual(RtModalKey.decide(characters: "a", command: false, shift: false, option: false, control: false, stripShown: true), .close)
        XCTAssertEqual(RtModalKey.decide(characters: "a", command: false, shift: false, option: false, control: false, stripShown: false), .pass)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile failure on the new names.

- [ ] **Step 3: Implement**

`Sources/FlockCore/Rt/RtItem.swift`:

```swift
import Foundation

public enum RtStrip: Equatable, Sendable {
    case exited(Int32?)
    case finished(Int32?)

    public var text: String {
        switch self {
        case .exited(let status):
            return "exited\(status.map { " \($0)" } ?? "") · any key closes"
        case .finished(let status):
            return "finished\(status.map { " · exit \($0)" } ?? "") · any key closes"
        }
    }
}

extension RtKind {
    public var defaultTitle: String {
        switch self {
        case .nav: "nav"
        case .glitter: "glitter"
        case .run: "rt run"
        case .runner: "runner"
        }
    }
}

/// One thing a pane opened through rt, living in a hidden tab (a runner, in
/// its own hidden workspace), linked to that pane by its terminal.
public struct RtItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: RtKind
    public let linked: TerminalID
    public let workspaceID: WorkspaceID
    /// The tab flock opened first; tabs rt placed for "Launch all" follow it.
    public var tabIDs: [TabID]
    /// Where the typed lines go, and whose idleness ends a run's phase 1.
    public let firstPaneID: PaneID
    public var title: String
    public let folder: String
    public var isRunning: Bool
    public var strip: RtStrip?

    public init(
        id: String, kind: RtKind, linked: TerminalID, workspaceID: WorkspaceID, tabIDs: [TabID], firstPaneID: PaneID,
        title: String, folder: String, isRunning: Bool, strip: RtStrip?
    ) {
        self.id = id
        self.kind = kind
        self.linked = linked
        self.workspaceID = workspaceID
        self.tabIDs = tabIDs
        self.firstPaneID = firstPaneID
        self.title = title
        self.folder = folder
        self.isRunning = isRunning
        self.strip = strip
    }

    public var stateText: String {
        switch strip {
        case .exited: "exited"
        case .finished: "finished"
        case nil: isRunning ? "running" : "finished"
        }
    }

    public func modalTitle(home: String) -> String {
        let name = kind == .run ? title : kind.rawValue
        let place: String
        if folder == home {
            place = "~"
        } else if folder.hasPrefix(home + "/") {
            place = "~" + folder.dropFirst(home.count)
        } else {
            place = folder
        }
        return "\(name) · \(place)"
    }
}

public struct RtModal: Equatable, Sendable {
    public let itemID: String
    public var tabID: TabID
    /// A runner's service on screen instead of its board.
    public var serviceTabID: TabID?

    public init(itemID: String, tabID: TabID, serviceTabID: TabID?) {
        self.itemID = itemID
        self.tabID = tabID
        self.serviceTabID = serviceTabID
    }

    public var shownTabID: TabID { serviceTabID ?? tabID }
}

public enum RtButtonModel {
    public enum Appearance: Equatable, Sendable {
        case absent
        case rest
        case active(count: Int)
    }

    public static func appearance(rtInstalled: Bool, runningItems: Int, hasRunner: Bool) -> Appearance {
        guard rtInstalled else { return .absent }
        let count = runningItems + (hasRunner ? 1 : 0)
        return count > 0 ? .active(count: count) : .rest
    }
}

public struct RtMenuRow: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(RtKind)
        case show(String)
    }

    public let title: String
    public let action: Action
    public let startsSection: Bool
}

public enum RtMenuModel {
    public static func rows(hasRunner: Bool, runItems: [RtItem]) -> [RtMenuRow] {
        var rows = [
            RtMenuRow(title: "nav · browse files here", action: .open(.nav), startsSection: false),
            RtMenuRow(title: "glitter · git status", action: .open(.glitter), startsSection: false),
            RtMenuRow(title: "run · run a script…", action: .open(.run), startsSection: false),
            RtMenuRow(title: hasRunner ? "Show runner" : "runner", action: .open(.runner), startsSection: false),
        ]
        for (index, item) in runItems.enumerated() {
            rows.append(RtMenuRow(title: "\(item.title) · \(item.stateText)", action: .show(item.id), startsSection: index == 0))
        }
        return rows
    }
}

/// Which keys the modal takes before the terminal and the window see them:
/// ⌘W, which would otherwise close the window, and, while a strip is up, any
/// plain key. Other ⌘ keys always pass, so a strip never swallows ⌘Q.
public enum RtModalKey {
    public enum Decision: Equatable, Sendable { case close, pass }

    public static func decide(
        characters: String?, command: Bool, shift: Bool, option: Bool, control: Bool, stripShown: Bool
    ) -> Decision {
        if command, !shift, !option, !control, characters?.lowercased() == "w" { return .close }
        if stripShown, !command { return .close }
        return .pass
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Expected: `RtItemTests` 5/5, `RtModalKeyTests` 3/3.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: items, the modal, the button, the menu and the modal's keys

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: The coordinator: open, watch, outcomes, the modal

**Files:**
- Create: `Sources/FlockCore/Rt/RtCoordinator.swift`
- Create: `Tests/FlockCoreTests/RtTestSupport.swift`
- Create: `Tests/FlockCoreTests/RtCoordinatorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces (`@MainActor @Observable public final class RtCoordinator`):
  - `init(client:files:config:now:makeToken:notice:)`, `struct Config { pollInterval, confirmDelay, shutdownTimeout, shellWait: Duration; missLimit: Int; fileDirectory: URL }` (default directory `ScratchDirectory.url/rt`)
  - `public internal(set) var items: [String: RtItem]`, `public internal(set) var modal: RtModal?`, `var modalItem: RtItem?`
  - `open(_ kind:from pane: PaneRecord) async`, `show(_ id:) async`, `closeModal() async`, `selectModalTab(_:)`, `backToBoard() async`, `perform(_ action: RtMenuRow.Action, from:) async`
  - `runner(linkedTo:) -> RtItem?`, `runItems(linkedTo:) -> [RtItem]`, `buttonAppearance(linkedTo: TerminalID?, rtInstalled:) -> RtButtonModel.Appearance`, `menuRows(linkedTo:) -> [RtMenuRow]`
  - internal for Task 9 and tests: `watches`, `lifecycles`, `misses`, `model`, `openedOrder`, `opensInFlight`, `pendingWork: [UUID: Task]`, `lastVisibleFocus`, `startWatch(_:)`, `background(_:)`, `waitForShell(_:) async -> ShellFlavor`, `focusLinked(_:) async`, `forget(_:)`, `closeItem(_:) async`, `panes(of:)`, `cd(linkedTo:into:) async`
  - Task 9 adds `update(model:)`, `shutDown(_:) async`, `settle() async`; this task calls `shutDown` from `closeModal`, so Task 9's file must exist before this compiles. Create `RtCoordinator+Lifetime.swift` in this task with only `shutDown` and its helpers (Step 3b), and grow it in Task 9.

- [ ] **Step 1: Write the test support**

`Tests/FlockCoreTests/RtTestSupport.swift`:

```swift
import Foundation
@testable import FlockCore

/// A herdr snapshot in plain values: one visible workspace holding the pane
/// every rt test opens from, plus whatever a test or `FakeRtWorld` adds.
struct RtFixture {
    struct Workspace { var id: String; var label: String }
    struct Tab { var id: String; var workspace: String; var label: String; var number: Int }
    struct Pane { var id: String; var tab: String; var workspace: String; var terminal: String?; var cwd: String }

    static let linkedPaneID = PaneID(rawValue: "w1:p1")
    static let linkedTerminal = TerminalID(rawValue: "term_a1")

    var workspaces = [Workspace(id: "w1", label: "acme")]
    var tabs = [Tab(id: "w1:t1", workspace: "w1", label: "main", number: 1)]
    var panes = [Pane(id: "w1:p1", tab: "w1:t1", workspace: "w1", terminal: "term_a1", cwd: "/src/acme")]
    var focusedPane: String? = "w1:p1"

    func model() -> SessionModel {
        let workspaceJSON = workspaces.map { workspace -> [String: Any] in
            let active = tabs.first { $0.workspace == workspace.id }?.id ?? "\(workspace.id):t0"
            return ["workspace_id": workspace.id, "label": workspace.label, "number": 1, "active_tab_id": active, "agent_status": "unknown"]
        }
        let tabJSON = tabs.map { tab -> [String: Any] in
            ["tab_id": tab.id, "workspace_id": tab.workspace, "label": tab.label, "number": tab.number,
             "pane_count": panes.filter { $0.tab == tab.id }.count, "agent_status": "unknown"]
        }
        let paneJSON = panes.map { pane -> [String: Any] in
            var json: [String: Any] = [
                "pane_id": pane.id, "workspace_id": pane.workspace, "tab_id": pane.tab,
                "focused": pane.id == focusedPane, "agent_status": "unknown", "revision": 0, "cwd": pane.cwd,
            ]
            if let terminal = pane.terminal { json["terminal_id"] = terminal }
            return json
        }
        var snapshot: [String: Any] = [
            "version": "0.9.0", "protocol": 22, "workspaces": workspaceJSON, "tabs": tabJSON, "panes": paneJSON, "layouts": [],
        ]
        if let focusedPane, let pane = panes.first(where: { $0.id == focusedPane }) {
            snapshot["focused_pane_id"] = pane.id
            snapshot["focused_tab_id"] = pane.tab
            snapshot["focused_workspace_id"] = pane.workspace
        }
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: data))
    }

    var linkedPane: PaneRecord { model().panes[Self.linkedPaneID]! }
}

/// herdr and the disk in one. It answers the verbs rt's hidden terminals use,
/// and runs a typed line by a script: busy for so many polls of its pane, then
/// the status and result files the pane's env names are written.
final class FakeRtWorld: HerdrCommandClient, RtFileStore, @unchecked Sendable {
    struct Run {
        var busyPolls: Int
        var status: String?
        var out: String? = nil
        var foreground: [String] = ["bun"]
        /// Busy polls after the files land: a script rt typed into its own pane.
        var afterPolls: Int = 0
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var recorded: [(method: String, params: [String: JSONValue])] = []
    private var stored: [URL: String] = [:]
    private var scripts: [(prefix: String, run: Run)] = []
    private var running: [String: (left: Int, run: Run)] = [:]
    /// A self-launched script: one idle poll (rt gone, the shell not yet on
    /// the typed line), then busy for the rest.
    private var trailing: [String: (idle: Int, busy: Int)] = [:]
    private var confirming: Set<String> = []
    private var envByPane: [String: [String: String]] = [:]
    private var workspaceCounter = 0
    private var tabCounters: [String: Int] = [:]
    private var terminalCounter = 0
    private(set) var fixture = RtFixture()

    var failing: Set<String> = []
    var silentPanes: Set<String> = []
    /// Fail the next `process_info` for these panes, once each.
    var silentOnce: Set<String> = []
    var busyPanes: Set<String> = []
    var shell = "zsh"

    var calls: [(method: String, params: [String: JSONValue])] { locked { recorded } }

    func calls(_ method: String) -> [[String: JSONValue]] { calls.filter { $0.method == method }.map(\.params) }

    func typed(into pane: String) -> [String] {
        calls("pane.send_input").filter { Self.string($0["pane_id"]) == pane }.compactMap { Self.string($0["text"]) }
    }

    func script(_ prefix: String, _ run: Run) { locked { scripts.append((prefix, run)) } }

    func write(_ text: String, to url: URL) { locked { stored[url] = text } }

    /// Adds entities as if herdr already had them, for launch-time tests.
    func seed(workspace: String, label: String) { locked { fixture.workspaces.append(.init(id: workspace, label: label)) } }

    func seed(tab: String, in workspace: String, label: String, number: Int) {
        locked { fixture.tabs.append(.init(id: tab, workspace: workspace, label: label, number: number)) }
    }

    func seed(pane: String, tab: String, workspace: String, terminal: String) {
        locked { fixture.panes.append(.init(id: pane, tab: tab, workspace: workspace, terminal: terminal, cwd: "/src/acme")) }
    }

    func removeLinkedPane() { locked { fixture.panes.removeAll { $0.id == "w1:p1" } } }

    func moveLinkedPane(to newID: String) {
        locked {
            if let index = fixture.panes.firstIndex(where: { $0.id == "w1:p1" }) { fixture.panes[index].id = newID }
        }
    }

    func stripTerminals() {
        locked { for index in fixture.panes.indices { fixture.panes[index].terminal = nil } }
    }

    func focus(_ pane: String?) { locked { fixture.focusedPane = pane } }

    func model() -> SessionModel { locked { fixture.model() } }

    // MARK: RtFileStore

    func read(_ url: URL) -> String? { locked { stored[url] } }
    func delete(_ url: URL) { locked { stored[url] = nil } }
    func prepareDirectory(_ url: URL) {}

    // MARK: HerdrCommandClient

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        try locked { try answer(method, params) }
    }

    private func answer(_ method: String, _ params: [String: JSONValue]) throws -> Data {
        recorded.append((method, params))
        if failing.contains(method) { throw Failure() }
        switch method {
        case "workspace.create":
            workspaceCounter += 1
            let workspace = "wF\(workspaceCounter)"
            fixture.workspaces.append(.init(id: workspace, label: Self.string(params["label"]) ?? ""))
            return createTab(in: workspace, label: "zsh", params: params)
        case "tab.create":
            return createTab(in: Self.string(params["workspace_id"]) ?? "", label: Self.string(params["label"]) ?? "zsh", params: params)
        case "tab.rename":
            if let id = Self.string(params["tab_id"]), let index = fixture.tabs.firstIndex(where: { $0.id == id }) {
                fixture.tabs[index].label = Self.string(params["label"]) ?? ""
            }
        case "tab.close":
            let id = Self.string(params["tab_id"])
            fixture.tabs.removeAll { $0.id == id }
            fixture.panes.removeAll { $0.tab == id }
        case "workspace.close":
            let id = Self.string(params["workspace_id"])
            fixture.workspaces.removeAll { $0.id == id }
            fixture.tabs.removeAll { $0.workspace == id }
            fixture.panes.removeAll { $0.workspace == id }
        case "pane.send_input":
            let pane = Self.string(params["pane_id"]) ?? ""
            let text = Self.string(params["text"]) ?? ""
            if let index = scripts.firstIndex(where: { text.hasPrefix($0.prefix) }) {
                let run = scripts.remove(at: index).run
                if run.busyPolls == 0 { finish(pane, run) } else { running[pane] = (run.busyPolls, run) }
            }
        case "pane.send_keys":
            let pane = Self.string(params["pane_id"]) ?? ""
            let keys = Self.strings(params["keys"])
            if keys == ["ctrl+c"], let state = running[pane] {
                if state.run.foreground.contains("rt-ui") {
                    confirming.insert(pane)
                } else {
                    running[pane] = nil
                    finish(pane, Run(busyPolls: 0, status: "130"))
                }
            } else if keys == ["y"], confirming.remove(pane) != nil {
                running[pane] = nil
                finish(pane, Run(busyPolls: 0, status: "0"))
            }
        case "pane.process_info":
            let pane = Self.string(params["pane_id"]) ?? ""
            if silentPanes.contains(pane) || silentOnce.remove(pane) != nil { throw Failure() }
            var busy = busyPanes.contains(pane)
            var names = ["claude"]
            if var state = running[pane] {
                busy = true
                names = state.run.foreground
                state.left -= 1
                if state.left <= 0, !confirming.contains(pane) {
                    running[pane] = nil
                    finish(pane, state.run)
                } else {
                    running[pane] = state
                }
            } else if let tail = trailing[pane] {
                if tail.idle > 0 {
                    trailing[pane] = (tail.idle - 1, tail.busy)
                } else if tail.busy > 0 {
                    busy = true
                    trailing[pane] = (0, tail.busy - 1)
                } else {
                    trailing[pane] = nil
                }
            }
            return Self.processInfo(pane: pane, busy: busy, names: names, shell: shell)
        default:
            break
        }
        return Data("{}".utf8)
    }

    /// Tabs and panes are numbered within their workspace, so a workspace's
    /// first tab is always `<workspace>:t1` holding `<workspace>:p1`.
    private func createTab(in workspace: String, label: String, params: [String: JSONValue]) -> Data {
        let number = (tabCounters[workspace] ?? 0) + 1
        tabCounters[workspace] = number
        terminalCounter += 1
        let tab = "\(workspace):t\(number)"
        let pane = "\(workspace):p\(number)"
        let terminal = "term_\(terminalCounter)"
        fixture.tabs.append(.init(id: tab, workspace: workspace, label: label, number: number))
        fixture.panes.append(.init(id: pane, tab: tab, workspace: workspace, terminal: terminal, cwd: Self.string(params["cwd"]) ?? "/"))
        if case .object(let env) = params["env"] {
            envByPane[pane] = env.compactMapValues(Self.string)
        }
        return Data(#"{"result":{"type":"tab_created","tab":{"tab_id":"\#(tab)","workspace_id":"\#(workspace)"},"root_pane":{"pane_id":"\#(pane)","terminal_id":"\#(terminal)"}}}"#.utf8)
    }

    private func finish(_ pane: String, _ run: Run) {
        let env = envByPane[pane] ?? [:]
        if let status = run.status, let path = env["FLOCK_RT_STATUS"] { stored[URL(fileURLWithPath: path)] = status + "\n" }
        if let out = run.out, let path = env["FLOCK_RT_OUT"] { stored[URL(fileURLWithPath: path)] = out }
        if run.afterPolls > 0 { trailing[pane] = (idle: 1, busy: run.afterPolls) }
    }

    private static func processInfo(pane: String, busy: Bool, names: [String], shell: String) -> Data {
        let processes = busy
            ? names.enumerated().map { #"{"name":"\#($0.element)","pid":\#(731 + $0.offset)}"# }.joined(separator: ",")
            : #"{"name":"\#(shell)","pid":500}"#
        let group = busy ? 731 : 500
        return Data(#"{"result":{"process_info":{"pane_id":"\#(pane)","shell_pid":500,"foreground_process_group_id":\#(group),"foreground_processes":[\#(processes)]}}}"#.utf8)
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let values) = value { return values.compactMap(string) }
        return []
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@MainActor
final class TokenSource {
    private var tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }
    func next() -> String { tokens.isEmpty ? UUID().uuidString : tokens.removeFirst() }
}

@MainActor
func makeCoordinator(_ world: FakeRtWorld, tokens: [String] = ["tok1", "tok2", "tok3"], notices: NoticeLog? = nil) -> RtCoordinator {
    let source = TokenSource(tokens)
    return RtCoordinator(
        client: world, files: world,
        config: .init(
            pollInterval: .milliseconds(1), confirmDelay: .milliseconds(5), shutdownTimeout: .milliseconds(500),
            shellWait: .milliseconds(20), missLimit: 3, fileDirectory: rtTestDirectory
        ),
        makeToken: { source.next() },
        notice: { notices?.lines.append($0) }
    )
}

let rtTestDirectory = URL(fileURLWithPath: "/flock-rt-test", isDirectory: true)

func rtPaths(_ token: String) -> RtFilePaths { RtFilePaths(token: token, directory: rtTestDirectory) }

@MainActor
final class NoticeLog {
    var lines: [String] = []
}

let rtResultLine = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#
```

- [ ] **Step 2: Write the failing tests**

`Tests/FlockCoreTests/RtCoordinatorTests.swift`:

```swift
import XCTest
@testable import FlockCore

@MainActor
final class RtCoordinatorTests: XCTestCase {
    private func finishWatch(_ rt: RtCoordinator, _ token: String) async throws {
        let watch = try XCTUnwrap(rt.watches[token])
        await watch.value
    }

    func testNavOpensHiddenInTheSharedWorkspaceAndClosesWhenItQuits() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 2, status: "0", out: ""))
        let rt = makeCoordinator(world)

        await rt.open(.nav, from: world.fixture.linkedPane)

        let create = try XCTUnwrap(world.calls("workspace.create").first)
        XCTAssertEqual(FakeRtWorld.string(create["label"]), "flock:rt")
        XCTAssertEqual(FakeRtWorld.string(create["cwd"]), "/src/acme")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.rename").first?["label"]), "nav term_a1 tok1")
        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt nav >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#])
        XCTAssertEqual(rt.modal?.itemID, "tok1")

        try await finishWatch(rt, "tok1")

        XCTAssertNil(rt.modal)
        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wF1:t1")
    }

    func testASecondCommandOpensALabelledTabInTheSharedWorkspace() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.glitter, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        await rt.open(.glitter, from: world.fixture.linkedPane)

        let tab = try XCTUnwrap(world.calls("tab.create").first)
        XCTAssertEqual(FakeRtWorld.string(tab["workspace_id"]), "wF1")
        XCTAssertEqual(FakeRtWorld.string(tab["label"]), "glitter term_a1 tok2")
        XCTAssertEqual(world.calls("workspace.create").count, 1)
        XCTAssertEqual(rt.modal?.itemID, "tok2")
    }

    func testCdHereTypesIntoAnIdleLinkedPane() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1, status: "0", out: "/src/acme/it's web\n"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        await rt.open(.nav, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.typed(into: "w1:p1"), [#"cd '/src/acme/it'\''s web'"#])
        XCTAssertTrue(world.calls("pane.split").isEmpty)
    }

    func testCdHereSplitsABusyLinkedPane() async throws {
        let world = FakeRtWorld()
        world.busyPanes = ["w1:p1"]
        world.script("command rt nav", .init(busyPolls: 1, status: "0", out: "/src/acme/web\n"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        await rt.open(.nav, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        let split = try XCTUnwrap(world.calls("pane.split").first)
        XCTAssertEqual(FakeRtWorld.string(split["target_pane_id"]), "w1:p1")
        XCTAssertEqual(FakeRtWorld.string(split["cwd"]), "/src/acme/web")
        XCTAssertTrue(world.typed(into: "w1:p1").isEmpty)
    }

    func testAnUncleanExitHoldsTheModalOnAnExitedStripUntilClosed() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 1, status: "1"))
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(rt.modalItem?.strip, .exited(1))
        XCTAssertTrue(world.calls("tab.close").isEmpty)

        await rt.closeModal()

        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertEqual(world.calls("tab.close").count, 1)
    }

    func testARunTypesPhaseTwoAndFinishesWithItsStatus() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: rtResultLine + "\n"))
        world.script("cd '/src/acme/web' && pnpm run test", .init(busyPolls: 2, status: "0"))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.typed(into: "wF1:p1").last, #"cd '/src/acme/web' && pnpm run test; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(rt.items["tok1"]?.title, "pnpm run test")
        XCTAssertEqual(rt.items["tok1"]?.strip, .finished(0))
        XCTAssertEqual(rt.modal?.itemID, "tok1")
    }

    func testASelfLaunchedRunFinishesWithoutAnExitStatus() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: "", afterPolls: 3))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(rt.items["tok1"]?.strip, .finished(nil))
    }

    func testACancelledRunClosesItsModal() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "1", out: ""))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertNil(rt.modal)
        XCTAssertTrue(rt.items.isEmpty)
    }

    func testClosingNavEarlyShutsItDown() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.nav, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertEqual(FakeRtWorld.strings(world.calls("pane.send_keys").first?["keys"]), ["ctrl+c"])
        XCTAssertEqual(world.calls("tab.close").count, 1)
        XCTAssertTrue(rt.items.isEmpty)
    }

    func testClosingARunningRunKeepsItCountedOnTheButton() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertTrue(world.calls("tab.close").isEmpty)
        XCTAssertEqual(rt.buttonAppearance(linkedTo: RtFixture.linkedTerminal, rtInstalled: true), .active(count: 1))
        XCTAssertEqual(rt.menuRows(linkedTo: RtFixture.linkedTerminal).last?.title, "rt run · running")
        rt.watches["tok1"]?.cancel()
    }

    func testTheRunnerGetsItsOwnWorkspaceAndASecondOpenShowsIt() async throws {
        let world = FakeRtWorld()
        world.script("command rt runner", .init(busyPolls: 1000, status: "0", foreground: ["bun", "rt-ui"]))
        let rt = makeCoordinator(world)

        await rt.open(.runner, from: world.fixture.linkedPane)
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.create").first?["label"]), "flock:rt runner term_a1")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.rename").first?["label"]), "runner term_a1 tok1")
        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt runner --herdr; echo $? >"$FLOCK_RT_STATUS""#])

        await rt.closeModal()
        XCTAssertNil(rt.modal)
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))

        await rt.open(.runner, from: world.fixture.linkedPane)
        XCTAssertEqual(world.calls("workspace.create").count, 1)
        XCTAssertEqual(rt.modal?.itemID, "tok1")
        rt.watches["tok1"]?.cancel()
    }

    func testAFishShellGetsItsStatusVariable() async throws {
        let world = FakeRtWorld()
        world.shell = "fish"
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)

        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt glitter; echo $status >"$FLOCK_RT_STATUS""#])
        rt.watches["tok1"]?.cancel()
    }

    func testAFailedOpenLeavesNothingHalfOpenAndSaysWhy() async throws {
        let world = FakeRtWorld()
        world.failing = ["tab.rename"]
        let notices = NoticeLog()
        let rt = makeCoordinator(world, notices: notices)

        await rt.open(.nav, from: world.fixture.linkedPane)

        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wF1")
        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertNil(rt.modal)
        XCTAssertEqual(notices.lines.count, 1)
    }

    func testOpeningAnotherCommandClosesTheCurrentModalByItsRules() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.nav, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        await rt.open(.glitter, from: world.fixture.linkedPane)

        XCTAssertNil(rt.items["tok1"], "nav only lives inside the modal")
        XCTAssertEqual(rt.modal?.itemID, "tok2")
        rt.watches["tok2"]?.cancel()
    }

    func testAPaneHerdrStopsAnsweringForIsForgotten() async throws {
        let world = FakeRtWorld()
        world.silentPanes = ["wF1:p1"]
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertNil(rt.modal)
        XCTAssertTrue(world.calls("tab.close").isEmpty, "nothing answers, so there is nothing to close")
    }

    /// A herdr reconnect drops an answer; a live item must outlast it.
    func testOneUnansweredPollDoesNotForgetAnItem() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 3, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.glitter, from: world.fixture.linkedPane)
        world.silentOnce = ["wF1:p1"]

        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.calls("tab.close").count, 1, "it ran to its own clean end")
    }

    func testClosingTheModalHandsHerdrsFocusToTheLinkedPane() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())
        await rt.open(.run, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")
        rt.watches["tok1"]?.cancel()
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run `xcodegen`, then `RtCoordinatorTests`. Expected: compile failure, `cannot find 'RtCoordinator'`.

- [ ] **Step 3a: Implement the coordinator**

`Sources/FlockCore/Rt/RtCoordinator.swift`:

```swift
import Foundation
import Observation

/// Every rt command flock runs off the canvas: nav, glitter, run and runner,
/// each in a herdr pane flock owns (`RtLabels`), shown in the one modal and
/// linked to the pane it was opened from by that pane's terminal.
///
/// A command's life is `RtLifecycle`'s; this class carries out each outcome
/// over herdr (`RtHerdr`) and the two files the typed line writes
/// (`RtFileStore`). Links, shutdowns and launch adoption are in
/// `RtCoordinator+Lifetime`.
@MainActor
@Observable
public final class RtCoordinator {
    public struct Config: Sendable {
        public var pollInterval: Duration
        public var confirmDelay: Duration
        public var shutdownTimeout: Duration
        /// How long a new pane gets to show its shell at a prompt before a
        /// line is typed into it.
        public var shellWait: Duration
        /// Consecutive unanswered polls before an item is taken as gone. One
        /// dropped answer (a herdr reconnect) must not orphan a live runner.
        public var missLimit: Int
        public var fileDirectory: URL

        public init(
            pollInterval: Duration = .milliseconds(300),
            confirmDelay: Duration = .seconds(1),
            shutdownTimeout: Duration = .seconds(10),
            shellWait: Duration = .seconds(2),
            missLimit: Int = 10,
            fileDirectory: URL = ScratchDirectory.url.appendingPathComponent("rt", isDirectory: true)
        ) {
            self.pollInterval = pollInterval
            self.confirmDelay = confirmDelay
            self.shutdownTimeout = shutdownTimeout
            self.shellWait = shellWait
            self.missLimit = missLimit
            self.fileDirectory = fileDirectory
        }
    }

    public internal(set) var items: [String: RtItem] = [:]
    public internal(set) var modal: RtModal?

    let herdr: RtHerdr
    let files: any RtFileStore
    let config: Config
    let now: @MainActor () -> Date
    let makeToken: @MainActor () -> String
    let notice: @MainActor (String) -> Void

    @ObservationIgnored var lifecycles: [String: RtLifecycle] = [:]
    @ObservationIgnored var watches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var misses: [String: Int] = [:]
    @ObservationIgnored var shutdowns: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var model: SessionModel?
    @ObservationIgnored var openedOrder: [String] = []
    @ObservationIgnored var opensInFlight = 0
    @ObservationIgnored var adopted = false
    @ObservationIgnored var reaping: Set<String> = []
    @ObservationIgnored var seenTabs: Set<TabID> = []
    @ObservationIgnored var handledStrays: Set<TabID> = []
    @ObservationIgnored var lastSeenFocus: PaneID?
    @ObservationIgnored var lastVisibleFocus: PaneID?

    public init(
        client: any HerdrCommandClient,
        files: any RtFileStore = DiskRtFileStore(),
        config: Config = Config(),
        now: @escaping @MainActor () -> Date = { Date() },
        makeToken: @escaping @MainActor () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
        notice: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        herdr = RtHerdr(client: client)
        self.files = files
        self.config = config
        self.now = now
        self.makeToken = makeToken
        self.notice = notice
    }

    // MARK: - what the chrome reads

    public var modalItem: RtItem? {
        modal.flatMap { items[$0.itemID] }
    }

    public func runner(linkedTo terminal: TerminalID) -> RtItem? {
        items.values.first { $0.kind == .runner && $0.linked == terminal }
    }

    /// In the order they were opened, so the menu lists them the same way every time.
    public func runItems(linkedTo terminal: TerminalID) -> [RtItem] {
        openedOrder.compactMap { items[$0] }.filter { $0.kind == .run && $0.linked == terminal }
    }

    public func buttonAppearance(linkedTo terminal: TerminalID?, rtInstalled: Bool) -> RtButtonModel.Appearance {
        guard let terminal else { return .absent }
        return RtButtonModel.appearance(
            rtInstalled: rtInstalled,
            runningItems: runItems(linkedTo: terminal).filter(\.isRunning).count,
            hasRunner: runner(linkedTo: terminal) != nil
        )
    }

    public func menuRows(linkedTo terminal: TerminalID) -> [RtMenuRow] {
        RtMenuModel.rows(hasRunner: runner(linkedTo: terminal) != nil, runItems: runItems(linkedTo: terminal))
    }

    public func perform(_ action: RtMenuRow.Action, from pane: PaneRecord) async {
        switch action {
        case .open(let kind): await open(kind, from: pane)
        case .show(let id): await show(id)
        }
    }

    // MARK: - opening

    public func open(_ kind: RtKind, from pane: PaneRecord) async {
        guard let terminal = pane.terminalID else { return }
        if kind == .runner, let existing = runner(linkedTo: terminal) {
            await show(existing.id)
            return
        }
        opensInFlight += 1
        defer { opensInFlight -= 1 }
        let token = makeToken()
        let paths = RtFilePaths(token: token, directory: config.fileDirectory)
        files.prepareDirectory(config.fileDirectory)
        files.delete(paths.out)
        files.delete(paths.status)
        let env = ["FLOCK_RT_OUT": paths.out.path, "FLOCK_RT_STATUS": paths.status.path]
        let label = RtLabels.tabLabel(RtLabels.TabLink(kind: kind, terminal: terminal, token: token))
        var created: RtHerdr.Created?
        var ownsWorkspace = false
        do {
            let host: RtHerdr.Created
            if kind == .runner {
                host = try await herdr.createWorkspace(label: RtLabels.runnerWorkspaceLabel(linkedTo: terminal), cwd: pane.cwd, env: env)
                created = host
                ownsWorkspace = true
                try await herdr.renameTab(host.tabID, to: label)
            } else if let shared = sharedWorkspaceID {
                host = try await herdr.createTab(in: shared, label: label, cwd: pane.cwd, env: env)
                created = host
            } else {
                host = try await herdr.createWorkspace(label: RtLabels.sharedWorkspace, cwd: pane.cwd, env: env)
                created = host
                ownsWorkspace = true
                try await herdr.renameTab(host.tabID, to: label)
            }
            let shell = await waitForShell(host.rootPaneID)
            try await herdr.type(RtCommandLine.command(for: kind, shell: shell), into: host.rootPaneID)
            items[token] = RtItem(
                id: token, kind: kind, linked: terminal, workspaceID: host.workspaceID, tabIDs: [host.tabID],
                firstPaneID: host.rootPaneID, title: kind.defaultTitle, folder: pane.cwd, isRunning: true, strip: nil
            )
            lifecycles[token] = RtLifecycle(kind: kind, startedAt: now())
            openedOrder.append(token)
            await show(token)
            startWatch(token)
        } catch {
            notice("rt \(kind.rawValue) failed: \(RtHerdr.describe(error))")
            if let created {
                if ownsWorkspace {
                    try? await herdr.closeWorkspace(created.workspaceID)
                } else {
                    try? await herdr.closeTab(created.tabID)
                }
            }
            files.delete(paths.out)
            files.delete(paths.status)
        }
    }

    var sharedWorkspaceID: WorkspaceID? {
        model?.workspaces.first { $0.label == RtLabels.sharedWorkspace }?.workspaceID
    }

    /// Waits, bounded, for the new pane's shell to stand alone in its
    /// foreground and name itself: before that its startup can hold the
    /// foreground (fish running config subprocesses) and a typed line can be
    /// lost. Past the bound, the user's login shell decides the status
    /// variable.
    func waitForShell(_ pane: PaneID) async -> ShellFlavor {
        let deadline = ContinuousClock.now.advanced(by: config.shellWait)
        while ContinuousClock.now < deadline {
            if let state = await herdr.paneState(pane), !state.busy, let name = state.shellName {
                return ShellFlavor(processName: name)
            }
            try? await Task.sleep(for: config.pollInterval)
        }
        let loginShell = ProcessInfo.processInfo.environment["SHELL"].map { URL(fileURLWithPath: $0).lastPathComponent }
        return ShellFlavor(processName: loginShell)
    }

    /// Runs `work` in the background, kept in `pendingWork` only while it runs.
    func background(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingWork[id] = Task { [weak self] in
            await work()
            self?.pendingWork[id] = nil
        }
    }

    // MARK: - the modal

    /// Another item's modal is closed by `closeModal`'s rules first.
    public func show(_ id: String) async {
        if let current = modal, current.itemID != id { await closeModal() }
        guard let item = items[id] else { return }
        modal = RtModal(itemID: id, tabID: item.tabIDs[0], serviceTabID: nil)
    }

    /// nav and glitter exist only inside the modal, so closing one early
    /// shuts it down; an rt run or a runner keeps going, hidden. Anything on a
    /// strip is over, and goes. Either way herdr's focus goes to the pane the
    /// item belongs to, which the rt button's click never moved to.
    public func closeModal() async {
        guard let current = modal else { return }
        modal = nil
        guard let item = items[current.itemID] else { return }
        // Before the shutdown, which waits out its confirm delay: focus moves
        // with the close, not a second after it.
        await focusLinked(item.linked)
        if item.strip != nil {
            await closeItem(item.id)
        } else {
            switch item.kind {
            case .nav, .glitter: await shutDown(item.id)
            case .run, .runner: break
            }
        }
    }

    func focusLinked(_ terminal: TerminalID) async {
        guard let model, let pane = pane(for: terminal, in: model) else { return }
        try? await herdr.focus(pane.paneID)
    }

    public func selectModalTab(_ tab: TabID) {
        guard let current = modal, items[current.itemID]?.tabIDs.contains(tab) == true else { return }
        modal?.tabID = tab
    }

    /// Closing an attach tab detaches from the service; the service runs on.
    public func backToBoard() async {
        guard let current = modal, current.serviceTabID != nil, let item = items[current.itemID], item.kind == .runner else { return }
        modal?.serviceTabID = nil
        let attachTabs = (model?.tabs[item.workspaceID] ?? []).map(\.tabID).filter { $0 != item.tabIDs[0] }
        for tab in attachTabs {
            try? await herdr.closeTab(tab)
        }
    }

    // MARK: - watching

    /// `self` is taken weakly on every poll, so a coordinator that goes away
    /// ends its watches rather than being kept alive by them.
    func startWatch(_ id: String) {
        watches[id]?.cancel()
        let interval = config.pollInterval
        watches[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard await self.poll(id) else { return }
            }
        }
    }

    /// One poll and whatever its outcome asks for. Whether to keep watching.
    /// A pane closed in herdr is dropped by `update(model:)`; unanswered polls
    /// alone forget an item only once they run to `missLimit`.
    private func poll(_ id: String) async -> Bool {
        guard let item = items[id] else { return false }
        let observation = await observe(item)
        guard !Task.isCancelled else { return false }
        guard let observation else {
            let missed = (misses[id] ?? 0) + 1
            misses[id] = missed
            guard missed >= config.missLimit else { return true }
            forget(id)
            return false
        }
        misses[id] = nil
        guard var lifecycle = lifecycles[id] else { return false }
        let outcome = lifecycle.observe(observation)
        lifecycles[id] = lifecycle
        return await apply(outcome, to: id)
    }

    private func observe(_ item: RtItem) async -> RtLifecycle.Observation? {
        guard let first = await herdr.paneState(item.firstPaneID) else { return nil }
        var anyBusy = first.busy
        for pane in panes(of: item) where pane != item.firstPaneID && !anyBusy {
            if await herdr.paneState(pane)?.busy == true { anyBusy = true }
        }
        let paths = RtFilePaths(token: item.id, directory: config.fileDirectory)
        let statusText = files.read(paths.status)
        return RtLifecycle.Observation(
            firstPaneBusy: first.busy, anyPaneBusy: anyBusy, statusExists: statusText != nil,
            status: RtFileParse.status(statusText), out: files.read(paths.out), now: now()
        )
    }

    /// Whether to keep watching.
    private func apply(_ outcome: RtLifecycle.Outcome, to id: String) async -> Bool {
        switch outcome {
        case .watching:
            return true
        case .typePhaseTwo(let result):
            guard let item = items[id] else { return false }
            files.delete(RtFilePaths(token: id, directory: config.fileDirectory).status)
            let shell = ShellFlavor(processName: await herdr.paneState(item.firstPaneID)?.shellName)
            do {
                try await herdr.type(RtCommandLine.phaseTwo(result, shell: shell), into: item.firstPaneID)
            } catch {
                notice("rt run failed: \(RtHerdr.describe(error))")
                await closeItem(id)
                return false
            }
            items[id]?.title = result.commandTemplate
            lifecycles[id]?.phaseTwoTyped(at: now())
            return true
        case .closeTab, .runnerEnded:
            let linked = items[id]?.linked
            let wasShown = modal?.itemID == id
            await closeItem(id)
            if wasShown, let linked { await focusLinked(linked) }
            return false
        case .cdLinkedPane(let path):
            let linked = items[id]?.linked
            await closeItem(id)
            if let linked { await cd(linkedTo: linked, into: path) }
            return false
        case .exited(let status):
            items[id]?.isRunning = false
            items[id]?.strip = .exited(status)
            return false
        case .finished(let status):
            items[id]?.isRunning = false
            items[id]?.strip = .finished(status)
            return false
        }
    }

    /// A linked pane at its prompt takes the `cd` and the focus; a busy one
    /// (an agent running, or one herdr cannot say) is split at the folder
    /// instead, and the split takes the focus.
    func cd(linkedTo terminal: TerminalID, into path: String) async {
        guard let model, let pane = pane(for: terminal, in: model) else { return }
        do {
            if await herdr.paneState(pane.paneID)?.busy == false {
                try await herdr.type(RtCommandLine.cd(path), into: pane.paneID)
                try await herdr.focus(pane.paneID)
            } else {
                try await herdr.split(pane.paneID, cwd: path)
            }
        } catch {
            notice("cd here failed: \(RtHerdr.describe(error))")
        }
    }

    /// Every pane in the item's tabs. A runner's attach tabs are not in
    /// `tabIDs`: they are views onto services, not the runner's own panes.
    func panes(of item: RtItem) -> [PaneID] {
        guard let model else { return [item.firstPaneID] }
        let found = item.tabIDs.flatMap { panes(inTab: $0, of: model) }
        return found.isEmpty ? [item.firstPaneID] : found
    }

    // MARK: - ending

    /// herdr no longer answers for the item: only flock's record of it goes.
    func forget(_ id: String) {
        items[id] = nil
        lifecycles[id] = nil
        watches[id] = nil
        misses[id] = nil
        openedOrder.removeAll { $0 == id }
        if modal?.itemID == id { modal = nil }
        let paths = RtFilePaths(token: id, directory: config.fileDirectory)
        files.delete(paths.out)
        files.delete(paths.status)
    }

    func closeItem(_ id: String) async {
        guard let item = items[id] else { return }
        forget(id)
        if item.kind == .runner {
            try? await herdr.closeWorkspace(item.workspaceID)
        } else {
            for tab in item.tabIDs {
                try? await herdr.closeTab(tab)
            }
        }
    }
}
```

- [ ] **Step 3b: Start the lifetime file with shutdown**

`Sources/FlockCore/Rt/RtCoordinator+Lifetime.swift`:

```swift
import Foundation

extension RtCoordinator {
    enum Closing: Sendable {
        case tabs([TabID])
        case workspace(WorkspaceID)
    }

    public func shutDown(_ id: String) async {
        if let running = shutdowns[id] {
            await running.value
            return
        }
        guard let item = items[id] else { return }
        watches.removeValue(forKey: id)?.cancel()
        items[id]?.isRunning = false
        let targets = item.kind == .runner ? [item.firstPaneID] : panes(of: item)
        let closing: Closing = item.kind == .runner ? .workspace(item.workspaceID) : .tabs(item.tabIDs)
        let task = Task { [weak self] in
            await self?.stop(targets)
            self?.forget(id)
            await self?.close(closing)
        }
        shutdowns[id] = task
        await task.value
        shutdowns[id] = nil
        reaping.remove(id)
    }

    /// `ctrl+c`, then `y` only where rt's own UI is still up a second later:
    /// that is a confirm (a board with services running), and a `y` sent
    /// anywhere else could answer some other program's prompt. SIGHUP from the
    /// close that follows is the backstop.
    func stop(_ panes: [PaneID]) async {
        for pane in panes {
            if await herdr.paneState(pane)?.busy == true {
                try? await herdr.sendKeys(["ctrl+c"], to: pane)
            }
        }
        try? await Task.sleep(for: config.confirmDelay)
        for pane in panes {
            if await herdr.paneState(pane)?.foregroundNames.contains("rt-ui") == true {
                try? await herdr.sendKeys(["y"], to: pane)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: config.shutdownTimeout)
        while ContinuousClock.now < deadline {
            var busy = false
            for pane in panes where !busy {
                if await herdr.paneState(pane)?.busy == true { busy = true }
            }
            if !busy { return }
            try? await Task.sleep(for: config.pollInterval)
        }
    }

    func close(_ closing: Closing) async {
        switch closing {
        case .tabs(let tabs):
            for tab in tabs {
                try? await herdr.closeTab(tab)
            }
        case .workspace(let workspace):
            try? await herdr.closeWorkspace(workspace)
        }
    }

    func panes(inTab tab: TabID, of model: SessionModel) -> [PaneID] {
        model.panes.values.filter { $0.tabID == tab }.map(\.paneID).sorted { $0.rawValue < $1.rawValue }
    }

    func isFlockOwned(_ workspace: WorkspaceID, in model: SessionModel) -> Bool {
        model.workspaces.first { $0.workspaceID == workspace }.map { RtLabels.isFlockOwned(workspaceLabel: $0.label) } ?? false
    }

    func pane(for terminal: TerminalID, in model: SessionModel) -> PaneRecord? {
        model.panes.values.first { $0.terminalID == terminal && !isFlockOwned($0.workspaceID, in: model) }
    }

    /// Keeps the full model, which `cd` and the attach tabs read.
    public func update(model newModel: SessionModel?) {
        guard let newModel else { return }
        model = newModel
    }

    /// Waits out every task this coordinator started in the background,
    /// including any those tasks start in turn.
    public func settle() async {
        while let task = pendingWork.values.first ?? shutdowns.values.first {
            await task.value
            await Task.yield()
        }
    }
}
```

A `for` loop's `where` clause cannot `await`, which is why the busy and `rt-ui` checks sit inside the loop bodies.

- [ ] **Step 4: Run the tests to see them pass**

Run `xcodegen`, then `RtCoordinatorTests`. Expected: 17/17. Then the whole `FlockCoreTests`.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: the coordinator opens, watches and closes commands in hidden panes

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Links: shutdown with the pane, launch adoption, stray tabs, focus

**Files:**
- Modify: `Sources/FlockCore/Rt/RtCoordinator+Lifetime.swift` (replace the placeholder `update(model:)`)
- Create: `Tests/FlockCoreTests/RtCoordinatorLifetimeTests.swift`

**Interfaces:**
- Consumes: Task 8's internals.
- Produces: `update(model:)` that adopts at launch, claims stray tabs, reaps items whose linked terminal is gone, drops items whose tabs were closed elsewhere, and follows focus into attach tabs; `orphan(_:panes:token:)`; `linkedTerminals(in:) -> Set<TerminalID>?`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlockCoreTests/RtCoordinatorLifetimeTests.swift`:

```swift
import XCTest
@testable import FlockCore

@MainActor
final class RtCoordinatorLifetimeTests: XCTestCase {
    private func openRunner(_ world: FakeRtWorld, _ rt: RtCoordinator) async {
        world.script("command rt runner", .init(busyPolls: 100_000, status: "0", foreground: ["bun", "rt-ui"]))
        await rt.open(.runner, from: world.fixture.linkedPane)
        rt.update(model: world.model())
    }

    func testClosingTheLinkedPaneStopsItsRunnerCleanly() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.removeLinkedPane()
        rt.update(model: world.model())
        await rt.settle()

        let keys = world.calls("pane.send_keys").map { FakeRtWorld.strings($0["keys"]) }
        XCTAssertEqual(keys, [["ctrl+c"], ["y"]])
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wF1")
        XCTAssertNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
    }

    func testAMovedLinkedPaneKeepsItsRunner() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.moveLinkedPane(to: "w1:p9")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertTrue(world.calls("pane.send_keys").isEmpty)
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
    }

    func testWithoutTerminalIDsNothingIsReaped() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.stripTerminals()
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
    }

    func testANewTabNotYetInTheModelIsNotDropped() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        rt.update(model: RtFixture().model())

        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: RtFixture().model())

        XCTAssertNotNil(rt.items["tok1"])
        rt.watches["tok1"]?.cancel()
    }

    func testAnItemWhoseTabClosedElsewhereIsForgotten() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        rt.update(model: RtFixture().model())

        XCTAssertNil(rt.items["tok1"])
        XCTAssertTrue(world.calls("tab.close").isEmpty)
    }

    func testLaunchAdoptsALiveRunnerAndShutsDownAStaleNav() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wR", label: "flock:rt runner term_a1")
        world.seed(tab: "wR:t1", in: "wR", label: "runner term_a1 old1", number: 1)
        world.seed(pane: "wR:p1", tab: "wR:t1", workspace: "wR", terminal: "term_r1")
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "nav term_a1 old2", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(rt.runner(linkedTo: RtFixture.linkedTerminal)?.id, "old1")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
        rt.watches["old1"]?.cancel()
    }

    func testLaunchClosesARunnerWhoseBoardExited() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wR", label: "flock:rt runner term_a1")
        world.seed(tab: "wR:t1", in: "wR", label: "runner term_a1 old1", number: 1)
        world.seed(pane: "wR:p1", tab: "wR:t1", workspace: "wR", terminal: "term_r1")
        world.write("0\n", to: rtPaths("old1").status)
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wR")
    }

    func testLaunchAdoptsARunInItsPhase() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "run term_a1 old3", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        world.write(rtResultLine + "\n", to: rtPaths("old3").out)
        let rt = makeCoordinator(world)

        rt.update(model: world.model())

        let item = try XCTUnwrap(rt.items["old3"])
        XCTAssertEqual(item.title, "pnpm run test")
        XCTAssertTrue(item.isRunning)
        XCTAssertEqual(rt.lifecycles["old3"]?.stage, .script)
        rt.watches["old3"]?.cancel()
    }

    func testAStrayTabJoinsTheRunStillPicking() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        world.seed(tab: "wF1:t9", in: "wF1", label: "zsh", number: 2)
        world.seed(pane: "wF1:p9", tab: "wF1:t9", workspace: "wF1", terminal: "term_9")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(rt.items["tok1"]?.tabIDs, [TabID(rawValue: "wF1:t1"), TabID(rawValue: "wF1:t9")])
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.rename").last?["label"]), "run term_a1 tok1")
        rt.watches["tok1"]?.cancel()
    }

    func testAStrayTabWithNoRunPickingIsShutDown() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "zsh", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
    }

    func testFocusOnAnAttachTabOpensTheServiceViewAndHandsFocusBack() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.seed(tab: "wF1:t7", in: "wF1", label: "bg:p3", number: 2)
        world.seed(pane: "wF1:p7", tab: "wF1:t7", workspace: "wF1", terminal: "term_7")
        world.focus("wF1:p7")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(rt.modal?.serviceTabID, TabID(rawValue: "wF1:t7"))
        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")

        await rt.backToBoard()
        XCTAssertNil(rt.modal?.serviceTabID)
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t7")
        rt.watches["tok1"]?.cancel()
    }

    /// A flock tab nothing owns (an orphan on its way out, a click in the
    /// herdr TUI) still hands herdr's focus back, to the last visible pane.
    func testFocusOnAnUnownedFlockTabGoesBackToTheLastVisiblePane() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "run term_gone old9", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        world.focus("wS:p1")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: the reaping, adoption, stray and focus tests fail (the placeholder `update` only stores the model).

- [ ] **Step 3: Implement**

Replace the placeholder `update(model:)` in `RtCoordinator+Lifetime.swift` with the reconciliation below, keeping the rest of the file:

```swift
    /// The full model, flock-owned workspaces included. Called on every model
    /// change; a nil model is a gap in the connection and changes nothing.
    public func update(model newModel: SessionModel?) {
        guard let newModel else { return }
        model = newModel
        seenTabs.formUnion(newModel.tabs.values.flatMap { $0 }.map(\.tabID))
        if !adopted, let present = linkedTerminals(in: newModel) {
            adopted = true
            adopt(newModel, present: present)
        }
        claimStrayTabs(newModel)
        reapGoneLinks(newModel)
        dropClosedTabs(newModel)
        followFocus(newModel)
    }

    /// Terminals of every pane outside flock's own workspaces, or nil when any
    /// of those panes came without one: links cannot be judged then, so
    /// nothing is reaped or adopted.
    func linkedTerminals(in model: SessionModel) -> Set<TerminalID>? {
        var terminals = Set<TerminalID>()
        for pane in model.panes.values where !isFlockOwned(pane.workspaceID, in: model) {
            guard let terminal = pane.terminalID else { return nil }
            terminals.insert(terminal)
        }
        return terminals
    }

    /// Something flock owns but will not keep: stopped cleanly, closed, and
    /// its files deleted when its label named a token.
    func orphan(_ closing: Closing, panes: [PaneID], token: String? = nil) {
        if case .tabs(let tabs) = closing { handledStrays.formUnion(tabs) }
        background { [weak self] in
            await self?.stop(panes)
            await self?.close(closing)
            if let self, let token {
                let paths = RtFilePaths(token: token, directory: self.config.fileDirectory)
                self.files.delete(paths.out)
                self.files.delete(paths.status)
            }
        }
    }

    // MARK: - launch

    private func adopt(_ model: SessionModel, present: Set<TerminalID>) {
        for workspace in model.workspaces where RtLabels.isFlockOwned(workspaceLabel: workspace.label) {
            let tabs = (model.tabs[workspace.workspaceID] ?? []).sorted { $0.number < $1.number }
            if workspace.label == RtLabels.sharedWorkspace {
                for tab in tabs {
                    adoptSharedTab(tab, model: model, present: present)
                }
            } else {
                adoptRunner(workspace, board: tabs.first, model: model, present: present)
            }
        }
    }

    private func adoptRunner(_ workspace: WorkspaceRecord, board: TabRecord?, model: SessionModel, present: Set<TerminalID>) {
        if let label = board?.label, let token = RtLabels.tabLink(fromLabel: label)?.token, items[token] != nil { return }
        let boardPanes = board.map { panes(inTab: $0.tabID, of: model) } ?? []
        guard let board, let link = RtLabels.tabLink(fromLabel: board.label), link.kind == .runner,
              present.contains(link.terminal), let first = boardPanes.first,
              files.read(RtFilePaths(token: link.token, directory: config.fileDirectory).status) == nil
        else {
            orphan(.workspace(workspace.workspaceID), panes: boardPanes, token: board.flatMap { RtLabels.tabLink(fromLabel: $0.label)?.token })
            return
        }
        items[link.token] = RtItem(
            id: link.token, kind: .runner, linked: link.terminal, workspaceID: workspace.workspaceID,
            tabIDs: [board.tabID], firstPaneID: first, title: RtKind.runner.defaultTitle,
            folder: model.panes[first]?.cwd ?? "", isRunning: true, strip: nil
        )
        lifecycles[link.token] = RtLifecycle(kind: .runner, startedAt: now())
        openedOrder.append(link.token)
        startWatch(link.token)
    }

    /// nav and glitter only exist inside a modal, and there is none after a
    /// restart, so only rt runs are adopted. The files say which phase one is in.
    private func adoptSharedTab(_ tab: TabRecord, model: SessionModel, present: Set<TerminalID>) {
        // Already known: opened before the first model arrived, or a second tab
        // of an item adopted a moment ago ("Launch all").
        if let token = RtLabels.tabLink(fromLabel: tab.label)?.token, let existing = items[token] {
            if !existing.tabIDs.contains(tab.tabID) { items[token]?.tabIDs.append(tab.tabID) }
            return
        }
        let tabPanes = panes(inTab: tab.tabID, of: model)
        guard let link = RtLabels.tabLink(fromLabel: tab.label), link.kind == .run,
              present.contains(link.terminal), let first = tabPanes.first
        else {
            orphan(.tabs([tab.tabID]), panes: tabPanes, token: RtLabels.tabLink(fromLabel: tab.label)?.token)
            return
        }
        let paths = RtFilePaths(token: link.token, directory: config.fileDirectory)
        let statusText = files.read(paths.status)
        let result = RtFileParse.runResult(files.read(paths.out))
        let stage: RtLifecycle.Stage
        var strip: RtStrip?
        switch (result, statusText) {
        case (.some, .some):
            stage = .done
            strip = .finished(RtFileParse.status(statusText))
        case (.some, .none):
            stage = .script
        case (.none, .none):
            stage = .picking
        case (.none, .some):
            guard RtFileParse.status(statusText) == 0 else {
                orphan(.tabs([tab.tabID]), panes: tabPanes, token: link.token)
                return
            }
            stage = .selfLaunched
        }
        items[link.token] = RtItem(
            id: link.token, kind: .run, linked: link.terminal, workspaceID: tab.workspaceID, tabIDs: [tab.tabID],
            firstPaneID: first, title: result?.commandTemplate ?? RtKind.run.defaultTitle,
            folder: model.panes[first]?.cwd ?? "", isRunning: stage != .done, strip: strip
        )
        lifecycles[link.token] = RtLifecycle.resumed(kind: .run, stage: stage, at: now())
        openedOrder.append(link.token)
        if stage != .done { startWatch(link.token) }
    }

    // MARK: - every update

    /// A tab in `flock:rt` with no link is one rt placed for "Launch all",
    /// while its picker was still running. Skipped while an open is in flight:
    /// a workspace's first tab is unlabelled until its rename lands.
    private func claimStrayTabs(_ model: SessionModel) {
        guard opensInFlight == 0 else { return }
        let owned = Set(items.values.flatMap(\.tabIDs))
        for workspace in model.workspaces where workspace.label == RtLabels.sharedWorkspace {
            for tab in model.tabs[workspace.workspaceID] ?? [] {
                guard RtLabels.tabLink(fromLabel: tab.label) == nil, !owned.contains(tab.tabID),
                      !handledStrays.contains(tab.tabID) else { continue }
                handledStrays.insert(tab.tabID)
                guard let owner = strayOwner(), let item = items[owner] else {
                    orphan(.tabs([tab.tabID]), panes: panes(inTab: tab.tabID, of: model))
                    continue
                }
                items[owner]?.tabIDs.append(tab.tabID)
                let label = RtLabels.tabLabel(RtLabels.TabLink(kind: .run, terminal: item.linked, token: owner))
                background { [herdr] in try? await herdr.renameTab(tab.tabID, to: label) }
            }
        }
    }

    /// The run on screen if it can still be placing tabs, else the one opened
    /// last. A run places them while its picker runs, and the event for the
    /// last one can land after the pick has ended.
    private func strayOwner() -> String? {
        let placing = openedOrder.filter {
            let stage = lifecycles[$0]?.stage
            return stage == .picking || stage == .selfLaunched
        }
        if let shown = modal?.itemID, placing.contains(shown) { return shown }
        return placing.last
    }

    private func reapGoneLinks(_ model: SessionModel) {
        guard let present = linkedTerminals(in: model) else { return }
        for item in items.values where !present.contains(item.linked) && !reaping.contains(item.id) {
            reaping.insert(item.id)
            let id = item.id
            background { [weak self] in await self?.shutDown(id) }
        }
    }

    /// A tab counts as closed only once it has been seen: the event naming a
    /// new tab can arrive after herdr's answer to the create.
    private func dropClosedTabs(_ model: SessionModel) {
        let live = Set(model.tabs.values.flatMap { $0 }.map(\.tabID))
        for (id, item) in items where shutdowns[id] == nil && !reaping.contains(id) {
            let gone = item.tabIDs.filter { seenTabs.contains($0) && !live.contains($0) }
            guard !gone.isEmpty else { continue }
            if gone.contains(item.tabIDs[0]) {
                forget(id)
            } else {
                items[id]?.tabIDs.removeAll { gone.contains($0) }
                if let current = modal, current.itemID == id, gone.contains(current.tabID) {
                    modal?.tabID = item.tabIDs[0]
                }
            }
        }
        if let service = modal?.serviceTabID, seenTabs.contains(service), !live.contains(service) {
            modal?.serviceTabID = nil
        }
    }

    /// herdr's focus lands in a flock-owned workspace only from outside flock:
    /// a runner's focus key opening an attach tab, or the herdr TUI. An attach
    /// tab becomes the service view. Either way herdr's focus goes back: to
    /// the pane the item is linked to, or with no owning item, to the last
    /// visible pane herdr had, so the canvas is never left with none.
    private func followFocus(_ model: SessionModel) {
        let focused = model.focusedPaneID
        defer { lastSeenFocus = focused }
        guard let focused, focused != lastSeenFocus, let pane = model.panes[focused] else { return }
        guard isFlockOwned(pane.workspaceID, in: model) else {
            lastVisibleFocus = focused
            return
        }
        let owner = items.values.first {
            $0.workspaceID == pane.workspaceID && ($0.kind == .runner || $0.tabIDs.contains(pane.tabID))
        }
        if let owner, owner.kind == .runner, pane.tabID != owner.tabIDs[0] {
            modal = RtModal(itemID: owner.id, tabID: owner.tabIDs[0], serviceTabID: pane.tabID)
        }
        let back = owner.flatMap { self.pane(for: $0.linked, in: model)?.paneID }
            ?? lastVisibleFocus.flatMap { model.panes[$0] != nil ? $0 : nil }
        guard let back else { return }
        background { [herdr] in try? await herdr.focus(back) }
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run `RtCoordinatorLifetimeTests` and `RtCoordinatorTests`. Expected: 12/12 and 17/17. Then the whole `FlockCoreTests`.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: linked things die with their pane, survive a restart, and follow focus

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: SessionViewModel owns the coordinator

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift`
- Modify: `Tests/FlockCoreTests/SessionViewModelTests.swift`

**Interfaces:**
- Consumes: `RtCoordinator` (Tasks 8-9), `fullModel` (Task 3).
- Produces: `public let rt: RtCoordinator`; `init(..., rt: RtCoordinator? = nil)`; `public var canvasFocusedPaneID: PaneID?`.

- [ ] **Step 1: Write the failing tests**

Add to `SessionViewModelTests`:

```swift
    // MARK: - rt

    @MainActor
    func testTheRtCoordinatorHearsTheFullModel() async {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "nav term_a1 old", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: rt)

        viewModel.update(model: world.model(), connection: .live)
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
    }

    /// The modal's surface takes the keyboard; no canvas pane may also claim it.
    @MainActor
    func testTheCanvasHasNoFocusedPaneWhileTheModalIsUp() async {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: rt)
        viewModel.update(model: world.model(), connection: .live)
        XCTAssertEqual(viewModel.canvasFocusedPaneID, RtFixture.linkedPaneID)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        XCTAssertNil(viewModel.canvasFocusedPaneID)

        await rt.closeModal()
        XCTAssertEqual(viewModel.canvasFocusedPaneID, RtFixture.linkedPaneID)
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile failure on the `rt:` argument and `canvasFocusedPaneID`.

- [ ] **Step 3: Implement**

In `SessionViewModel`, add the property and the init parameter (last, defaulted):

```swift
    /// Everything opened through a pane's rt button.
    public let rt: RtCoordinator
```

```swift
        notificationLifetime: @escaping @MainActor () -> NotificationLifetime = { .untilSeen },
        navigationPollInterval: Duration = .milliseconds(300),
        rt: RtCoordinator? = nil
    ) {
        ...
        self.navigationPollInterval = navigationPollInterval
        self.rt = rt ?? RtCoordinator(client: client, notice: noticeSink)
    }
```

At the end of `update(model:connection:)`:

```swift
        rt.update(model: fullModel)
```

Beside `resolvedFocusedPaneID`:

```swift
    /// The pane the canvas draws as focused and lets take the keyboard: none
    /// while the rt modal is up, since the modal's own surface has it.
    public var canvasFocusedPaneID: PaneID? {
        rt.modal == nil ? resolvedFocusedPaneID : nil
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run `SessionViewModelTests`, then the whole `FlockCoreTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "session: own the rt coordinator and keep the canvas off the keyboard under its modal

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10b: One pane per hidden tab, the split pill, the popover's rows

rt opens a runner board in its own pane for a queue or a preset, so a hidden rt tab never gains panes or tabs: an item is one tab. The approved canvas (`docs/design/rt/measurements.md`) also merges the runner into the rt button (a split pill whose count is rt run items only) and replaces the native menu with a popover. This task changes the FlockCore types and the coordinator to match; Tasks 12 and 13 build the views on them.

**Files:**
- Modify: `Sources/FlockCore/Rt/RtItem.swift`
- Modify: `Sources/FlockCore/Rt/RtCoordinator.swift`
- Modify: `Sources/FlockCore/Rt/RtCoordinator+Lifetime.swift`
- Modify: `Tests/FlockCoreTests/RtItemTests.swift`, `Tests/FlockCoreTests/RtCoordinatorTests.swift`, `Tests/FlockCoreTests/RtCoordinatorLifetimeTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 7-10.
- Produces:
  - `RtItem.tabID: TabID` (replaces `tabIDs`); init label `tabID:`.
  - `RtButtonModel.Appearance`: `absent`, `rest`, `active(count: Int, runner: Bool)`.
  - `public struct RtCommandRow: Equatable, Sendable, Identifiable { kind: RtKind; title: String; hint: String; id: RtKind }` and `public enum RtPopoverModel { static func commands(hasRunner: Bool) -> [RtCommandRow] }`.
  - `public struct RtRunRow: Equatable, Sendable, Identifiable { enum Tone { running, finished, exited }; id: String; title: String; state: String; tone: Tone }` and `RtItem.runRow: RtRunRow`.
  - On `RtCoordinator`: `commandRows(linkedTo:) -> [RtCommandRow]`, `runRows(linkedTo:) -> [RtRunRow]`. Removed: `menuRows(linkedTo:)`, `perform(_:from:)`, `selectModalTab(_:)`, `RtMenuRow`, `RtMenuModel`, `RtItem.stateText`, and the stray-tab joining (`strayOwner`).

- [ ] **Step 1: Update the tests to the new shapes (they fail to compile, then fail)**

In `RtItemTests.swift`, the fixture takes `tabID: TabID(rawValue: "wF:t1")` in place of `tabIDs: [...]`, and three tests change:

```swift
    func testTheButtonRestsWithNothingRunningAndCountsRunItemsOnly() {
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: false, runningItems: 3, hasRunner: true), .absent)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: false), .rest)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: false), .active(count: 2, runner: false))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: true), .active(count: 2, runner: true))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: true), .active(count: 0, runner: true))
    }

    func testThePopoverOffersFourCommandsWithRtsOwnCommandAsAHint() {
        let rows = RtPopoverModel.commands(hasRunner: false)
        XCTAssertEqual(rows.map(\.title), ["Browse files", "Git status", "Run a script…", "Start runner"])
        XCTAssertEqual(rows.map(\.hint), ["rt nav", "rt glitter", "rt run", "rt runner"])
        XCTAssertEqual(rows.map(\.kind), [.nav, .glitter, .run, .runner])
        XCTAssertEqual(RtPopoverModel.commands(hasRunner: true).last?.title, "Show runner")
    }

    func testARunRowSaysWhereTheItemIs() {
        XCTAssertEqual(item().runRow, RtRunRow(id: "tok1", title: "pnpm run test", state: "running", tone: .running))
        XCTAssertEqual(item(running: false, strip: .finished(0)).runRow.state, "finished · exit 0")
        XCTAssertEqual(item(running: false, strip: .finished(nil)).runRow.state, "finished")
        XCTAssertEqual(item(running: false, strip: .exited(1)).runRow, RtRunRow(id: "tok1", title: "pnpm run test", state: "exited 1", tone: .exited))
        XCTAssertEqual(item(running: false, strip: .exited(nil)).runRow.state, "exited")
        XCTAssertEqual(item(running: false).runRow.tone, .finished)
    }
```

Delete `testTheMenuOffersTheCommandsThenThePanesItems` and `testTheRunnerRowShowsAnExistingRunner`; keep the strip, title and key tests as they are.

In `RtCoordinatorTests.testClosingARunningRunKeepsItCountedOnTheButton`, the two assertions become:

```swift
        XCTAssertEqual(rt.buttonAppearance(linkedTo: RtFixture.linkedTerminal, rtInstalled: true), .active(count: 1, runner: false))
        XCTAssertEqual(rt.runRows(linkedTo: RtFixture.linkedTerminal).last, RtRunRow(id: "tok1", title: "rt run", state: "running", tone: .running))
```

and in `testTheRunnerGetsItsOwnWorkspaceAndASecondOpenShowsIt`, after `XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))` add:

```swift
        XCTAssertEqual(rt.buttonAppearance(linkedTo: RtFixture.linkedTerminal, rtInstalled: true), .active(count: 0, runner: true))
        XCTAssertEqual(rt.commandRows(linkedTo: RtFixture.linkedTerminal).last?.title, "Show runner")
```

In `RtCoordinatorLifetimeTests`, replace `testAStrayTabJoinsTheRunStillPicking` with:

```swift
    /// A hidden tab holds one pane, so a tab rt did not open through flock is
    /// never an item's: it is shut down even while a run is picking.
    func testAStrayTabIsShutDownEvenWhileARunPicks() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        world.seed(tab: "wF1:t9", in: "wF1", label: "zsh", number: 2)
        world.seed(pane: "wF1:p9", tab: "wF1:t9", workspace: "wF1", terminal: "term_9")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t9")
        XCTAssertEqual(rt.items["tok1"]?.tabID, TabID(rawValue: "wF1:t1"))
        XCTAssertTrue(world.calls("tab.rename").allSatisfy { FakeRtWorld.string($0["tab_id"]) != "wF1:t9" })
        rt.watches["tok1"]?.cancel()
    }
```

Update every other `tabIDs` reference in the three test files to `tabID` (for example `rt.items["tok1"]?.tabIDs` becomes `rt.items["tok1"]?.tabID`).

- [ ] **Step 2: Run them to see them fail**

Run `RtItemTests`, `RtCoordinatorTests` and `RtCoordinatorLifetimeTests`. Expected: compile failures on `tabID`, `RtPopoverModel`, `RtRunRow`, `runRows`, `commandRows` and the two-value `active`.

- [ ] **Step 3: Implement**

In `RtItem.swift`:

- `RtItem`: replace `public var tabIDs: [TabID]` and its comment with

```swift
    /// The one tab the item lives in. A runner's attach tabs sit beside it in
    /// its workspace and are views onto services, never the item's own.
    public let tabID: TabID
```

  change the init parameter to `tabID: TabID`, and replace `stateText` with

```swift
    public var runRow: RtRunRow {
        switch strip {
        case .exited(let status):
            return RtRunRow(id: id, title: title, state: "exited\(status.map { " \($0)" } ?? "")", tone: .exited)
        case .finished(let status):
            return RtRunRow(id: id, title: title, state: "finished\(status.map { " · exit \($0)" } ?? "")", tone: .finished)
        case nil:
            return RtRunRow(id: id, title: title, state: isRunning ? "running" : "finished", tone: isRunning ? .running : .finished)
        }
    }
```

- `RtButtonModel`:

```swift
public enum RtButtonModel {
    public enum Appearance: Equatable, Sendable {
        case absent
        case rest
        /// `count` is running rt run items only; a live runner is the pill's
        /// second half, never counted again.
        case active(count: Int, runner: Bool)
    }

    public static func appearance(rtInstalled: Bool, runningItems: Int, hasRunner: Bool) -> Appearance {
        guard rtInstalled else { return .absent }
        guard runningItems > 0 || hasRunner else { return .rest }
        return .active(count: runningItems, runner: hasRunner)
    }
}
```

- Replace `RtMenuRow` and `RtMenuModel` with:

```swift
public struct RtCommandRow: Equatable, Sendable, Identifiable {
    public let kind: RtKind
    public let title: String
    /// rt's own command, shown so the popover teaches it.
    public let hint: String

    public var id: RtKind { kind }
}

public struct RtRunRow: Equatable, Sendable, Identifiable {
    public enum Tone: Equatable, Sendable { case running, finished, exited }

    public let id: String
    public let title: String
    public let state: String
    public let tone: Tone

    public init(id: String, title: String, state: String, tone: Tone) {
        self.id = id
        self.title = title
        self.state = state
        self.tone = tone
    }
}

public enum RtPopoverModel {
    public static func commands(hasRunner: Bool) -> [RtCommandRow] {
        [
            RtCommandRow(kind: .nav, title: "Browse files", hint: "rt nav"),
            RtCommandRow(kind: .glitter, title: "Git status", hint: "rt glitter"),
            RtCommandRow(kind: .run, title: "Run a script…", hint: "rt run"),
            RtCommandRow(kind: .runner, title: hasRunner ? "Show runner" : "Start runner", hint: "rt runner"),
        ]
    }
}
```

In `RtCoordinator.swift`:

- Replace `menuRows(linkedTo:)` and `perform(_:from:)` with

```swift
    public func commandRows(linkedTo terminal: TerminalID) -> [RtCommandRow] {
        RtPopoverModel.commands(hasRunner: runner(linkedTo: terminal) != nil)
    }

    /// In the order they were opened, so the popover lists them the same way every time.
    public func runRows(linkedTo terminal: TerminalID) -> [RtRunRow] {
        runItems(linkedTo: terminal).map(\.runRow)
    }
```

- Delete `selectModalTab(_:)`.
- Every `tabIDs: [host.tabID]` becomes `tabID: host.tabID`; `item.tabIDs[0]` becomes `item.tabID` (in `show`, `backToBoard`); `panes(of:)` reads `panes(inTab: item.tabID, of: model)`; `closeItem` closes `item.tabID`. Its doc comment keeps saying why attach tabs are not the item's.

In `RtCoordinator+Lifetime.swift`:

- `shutDown`: `.tabs([item.tabID])`.
- `adoptRunner`: `tabID: board.tabID`.
- `adoptSharedTab`: a tab whose token is already an item's returns at once (drop the append).
- `claimStrayTabs` becomes

```swift
    /// A tab in `flock:rt` with no link is none of flock's: every item is one
    /// tab flock opened and labelled. Skipped while an open is in flight: a
    /// workspace's first tab is unlabelled until its rename lands.
    private func claimStrayTabs(_ model: SessionModel) {
        guard opensInFlight == 0 else { return }
        let owned = Set(items.values.map(\.tabID))
        for workspace in model.workspaces where workspace.label == RtLabels.sharedWorkspace {
            for tab in model.tabs[workspace.workspaceID] ?? [] {
                guard RtLabels.tabLink(fromLabel: tab.label) == nil, !owned.contains(tab.tabID),
                      !handledStrays.contains(tab.tabID) else { continue }
                orphan(.tabs([tab.tabID]), panes: panes(inTab: tab.tabID, of: model))
            }
        }
    }
```

  and `strayOwner()` is deleted (`orphan` already records the tab in `handledStrays`).
- `dropClosedTabs`: an item whose `tabID` has been seen and is no longer live is forgotten; the service-tab rule is unchanged.

```swift
    private func dropClosedTabs(_ model: SessionModel) {
        let live = Set(model.tabs.values.flatMap { $0 }.map(\.tabID))
        for (id, item) in items where shutdowns[id] == nil && !reaping.contains(id) {
            if seenTabs.contains(item.tabID), !live.contains(item.tabID) { forget(id) }
        }
        if let service = modal?.serviceTabID, seenTabs.contains(service), !live.contains(service) {
            modal?.serviceTabID = nil
        }
    }
```

- `followFocus`: the owner is `items.values.first { $0.workspaceID == pane.workspaceID && ($0.kind == .runner || $0.tabID == pane.tabID) }`; the service view opens when `pane.tabID != owner.tabID`, as `RtModal(itemID: owner.id, tabID: owner.tabID, serviceTabID: pane.tabID)`.

Keep the doc comments true: anything that still mentions "Launch all" placing tabs, or tabs following the first, is rewritten or removed.

- [ ] **Step 4: Run the tests to see them pass**

Run `RtItemTests`, `RtCoordinatorTests`, `RtCoordinatorLifetimeTests`, then the whole `FlockCoreTests`. Expected: all pass (the lifetime class keeps 14 tests; `RtItemTests` has 5).

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: one pane per hidden tab, a split rt button, and the popover's rows

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10c: A queue or preset picked in rt run becomes the pane's runner

With `--resolve-only`, rt launches nothing for a queue ("Launch all", "Run now" after saving a preset) or a saved preset: it prints the seed rows as one JSON line, `{"seed":[{"name":…,"command":…,"cwd":…,"pkg":…,"repo":…}]}`, and exits 0. `rt runner --seed-file <path>` opens a board seeded from such a file, and composes with `--herdr`. flock turns that pick into the pane's runner: the rt run item closes, and the pane's runner opens from the seed in its own workspace, like any runner.

**Files:**
- Modify: `Sources/FlockCore/Rt/RtFiles.swift`, `Sources/FlockCore/Rt/RtCommandLine.swift`, `Sources/FlockCore/Rt/RtLifecycle.swift`, `Sources/FlockCore/Rt/RtCoordinator.swift`
- Modify: `Tests/FlockCoreTests/RtFilesTests.swift`, `RtCommandLineTests.swift`, `RtLifecycleTests.swift`, `RtCoordinatorTests.swift`, `RtTestSupport.swift` (only if `FakeRtWorld` needs it)

**Interfaces:**
- Produces: `RtFilePaths.seed` (`<token>.seed`); `RtFileStore.write(_:to:)`; `RtFileParse.seed(_:) -> String?`; `RtCommandLine.command(for:shell:seeded:)`; `RtLifecycle.Outcome.becomeRunner(String)`; `RtCoordinator.open(_:from:seed:reveal:)` (both new parameters defaulted: `seed: nil`, `reveal: true`).

- [ ] **Step 1: Write the failing tests**

`RtFilesTests`:

```swift
    func testASeedFileSitsBesideTheOthers() {
        let paths = RtFilePaths(token: "3f2a", directory: URL(fileURLWithPath: "/tmp/flock-rt", isDirectory: true))
        XCTAssertEqual(paths.seed.path, "/tmp/flock-rt/3f2a.seed")
    }

    /// A queue or preset picked under `--resolve-only` comes back as seed rows.
    func testASeedReadsOnlyAsANonEmptySeedEnvelope() {
        let seed = #"{"seed":[{"name":"dev","command":"pnpm run dev","cwd":"/src/acme/web","pkg":"web","repo":"acme"}]}"#
        XCTAssertEqual(RtFileParse.seed(seed + "\n"), seed)
        XCTAssertNil(RtFileParse.seed(#"{"seed":[]}"#))
        XCTAssertNil(RtFileParse.seed(#"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#))
        XCTAssertNil(RtFileParse.seed("/src/acme\n"))
        XCTAssertNil(RtFileParse.seed(nil))
    }
```

and in `testTheDiskStoreReadsDeletesAndMakesItsDirectory`, write through the store too: `store.write("0\n", to: url)` in place of `String.write`, then the existing read and delete assertions.

`RtCommandLineTests`:

```swift
    func testASeededRunnerReadsItsSeedFile() {
        XCTAssertEqual(
            RtCommandLine.command(for: .runner, shell: .posix, seeded: true),
            #"command rt runner --herdr --seed-file "$FLOCK_RT_SEED"; echo $? >"$FLOCK_RT_STATUS""#
        )
    }
```

`RtLifecycleTests`:

```swift
    func testAPickThatReturnsASeedBecomesARunner() {
        let seed = #"{"seed":[{"name":"dev","command":"pnpm run dev","cwd":"/src/acme/web"}]}"#
        var life = RtLifecycle(kind: .run, startedAt: start)
        _ = life.observe(seen(busy: true, at: 0.3))
        XCTAssertEqual(life.observe(seen(busy: false, status: 0, out: seed + "\n", at: 4)), .becomeRunner(seed))
        XCTAssertEqual(life.stage, .done)
    }
```

`RtCoordinatorTests` (with `let rtSeedLine = #"{"seed":[{"name":"dev","command":"pnpm run dev","cwd":"/src/acme/web","pkg":"web","repo":"acme"}]}"#` beside `rtResultLine` in `RtTestSupport.swift`):

```swift
    func testARunWhosePickReturnsASeedBecomesThePanesRunner() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: rtSeedLine + "\n"))
        world.script("command rt runner", .init(busyPolls: 100_000, status: "0", foreground: ["bun", "rt-ui"]))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wF1:t1")
        let create = try XCTUnwrap(world.calls("workspace.create").last)
        XCTAssertEqual(FakeRtWorld.string(create["label"]), "flock:rt runner term_a1")
        guard case .object(let env) = create["env"] else { return XCTFail("no env") }
        XCTAssertEqual(FakeRtWorld.string(env["FLOCK_RT_SEED"]), rtPaths("tok2").seed.path)
        XCTAssertEqual(world.read(rtPaths("tok2").seed), rtSeedLine)
        XCTAssertEqual(world.typed(into: "wF2:p1"), [#"command rt runner --herdr --seed-file "$FLOCK_RT_SEED"; echo $? >"$FLOCK_RT_STATUS""#])
        XCTAssertEqual(rt.runner(linkedTo: RtFixture.linkedTerminal)?.id, "tok2")
        XCTAssertNil(rt.items["tok1"])
        XCTAssertEqual(rt.modal?.itemID, "tok2")
        rt.watches["tok2"]?.cancel()
    }

    /// One runner per pane: the queue is not added to it, and the user is told.
    func testASeedWithARunnerAlreadyRunningShowsItAndSaysSo() async throws {
        let world = FakeRtWorld()
        world.script("command rt runner", .init(busyPolls: 100_000, status: "0", foreground: ["bun", "rt-ui"]))
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: rtSeedLine + "\n"))
        let notices = NoticeLog()
        let rt = makeCoordinator(world, notices: notices)
        rt.update(model: world.model())
        await rt.open(.runner, from: world.fixture.linkedPane)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok2")
        await rt.settle()

        XCTAssertEqual(world.calls("workspace.create").count, 2, "the runner's workspace and flock:rt, no second runner")
        XCTAssertEqual(rt.modal?.itemID, "tok1")
        XCTAssertEqual(notices.lines.count, 1)
        rt.watches["tok1"]?.cancel()
    }

    /// A run picked while hidden stays hidden as a runner: no modal pops up.
    func testASeedFromAHiddenRunOpensTheRunnerWithoutTheModal() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 5, status: "0", out: rtSeedLine + "\n"))
        world.script("command rt runner", .init(busyPolls: 100_000, status: "0", foreground: ["bun", "rt-ui"]))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())
        await rt.open(.run, from: world.fixture.linkedPane)
        await rt.closeModal()

        try await finishWatch(rt, "tok1")

        XCTAssertEqual(rt.runner(linkedTo: RtFixture.linkedTerminal)?.id, "tok2")
        XCTAssertNil(rt.modal)
        rt.watches["tok2"]?.cancel()
    }
```

Check each test's pane and workspace ids against `FakeRtWorld`'s numbering (workspaces `wF1`, `wF2` in creation order; a workspace's first pane is `<workspace>:p1`) and adjust ids only if the fake numbers differently; say so in the report.

- [ ] **Step 2: Run them to see them fail**

Expected: compile failures on `seed`, `write`, `seeded:`, `.becomeRunner`, and `open(_:from:seed:reveal:)`.

- [ ] **Step 3: Implement**

`RtFiles.swift`:

- `RtFilePaths` gains `public let seed: URL` = `directory.appendingPathComponent("\(token).seed")`.
- `RtFileStore` gains `func write(_ text: String, to url: URL)`; `DiskRtFileStore` writes atomically as UTF-8 (`try?`, like its siblings).
- `RtFileParse.seed(_ text: String?) -> String?`: the trimmed text when it decodes as `{"seed":[...]}` with at least one row whose `name`, `command` and `cwd` are strings; nil otherwise. flock only checks the shape; rt reads the rows.

`RtCommandLine.command(for:shell:seeded:)` (`seeded` defaulted to `false`): for `.runner` with `seeded`, the body is `command rt runner --herdr --seed-file "$FLOCK_RT_SEED"`; every other line is unchanged. The path reaches the shell through the tab's env, as `FLOCK_RT_OUT` and `FLOCK_RT_STATUS` do, so it is never quoted into the line.

`RtLifecycle`: `Outcome.becomeRunner(String)`; in `pickingOutcome`, after the `runResult` check and before the status-0 self-launch check, `if let seed = RtFileParse.seed(seen.out) { stage = .done; return .becomeRunner(seed) }`. The self-launch path stays for an rt that still launches a queue itself.

`RtCoordinator`:

- `open(_ kind: RtKind, from pane: PaneRecord, seed: String? = nil, reveal: Bool = true)`. For a seeded runner, before creating the workspace, `files.write(seed, to: paths.seed)` and add `"FLOCK_RT_SEED": paths.seed.path` to the env; the typed line is `RtCommandLine.command(for: kind, shell: shell, seeded: seed != nil)`. `show(token)` runs only when `reveal` is true. The error path deletes `paths.seed` along with the others.
- `forget` deletes `paths.seed` too.
- `apply`:

```swift
        case .becomeRunner(let seed):
            guard let item = items[id] else { return false }
            let wasShown = modal?.itemID == id
            await closeItem(id)
            if let existing = runner(linkedTo: item.linked) {
                notice("A runner is already running for this pane: add scripts from its board.")
                if wasShown { await show(existing.id) }
                return false
            }
            guard let model, let pane = pane(for: item.linked, in: model) else { return false }
            await open(.runner, from: pane, seed: seed, reveal: wasShown)
            return false
```

- [ ] **Step 4: Run the tests to see them pass**

Run the five changed classes, then the whole `FlockCoreTests`.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: a queue or preset picked in rt run becomes the pane's runner

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Design canvas (CHECKPOINT, controller only)

Visual work stays with the controller; do not dispatch it to an implementer. No UI code is written until Matt approves this canvas.

**Files:**
- Create: `docs/design/rt/flock-rt.pen` (via the pencil MCP only; never read or grep a `.pen`)
- Create: `docs/design/rt/*.png` (exports) and `docs/design/rt/measurements.md`

- [ ] **Step 1: Load the tools and the house style.** Load the pencil MCP tools with ToolSearch (`select:mcp__pencil__get_app_state,mcp__pencil__read_skill,mcp__pencil__execute,mcp__pencil__get_style`) and read its skill. Open `docs/design/chat/flock-chat.pen` and read `docs/design/chat/measurements.md` for the legend's chat button, fonts (Inter at the chrome's 1.28x), and theme roles. Tokyo Night and Tokyo Night Day are the two themes to draw.

- [ ] **Step 2: Draw the artboards**, each in dark and light:
  1. `legend-rt`: a pane title row with the chat button, then the rt button at rest (badge on the quiet square), the rt button active with a count (selection pill), and the runner button, per spec "The rt button" and "The runner button".
  2. `rt-menu`: the native menu with the four commands, a divider, and two item rows (`pnpm run test · running`, `pnpm run build · finished`).
  3. `modal-nav`: the window with the backdrop dimmed and the modal at about 80% showing a terminal, title row `nav · ~/src/acme` and the close control.
  4. `modal-strips`: the same modal with the exited strip, and with the finished strip.
  5. `modal-tabs`: an rt run item spanning two tabs, with the tab strip.
  6. `modal-service`: the runner's service view with `← runner` in the title row.

- [ ] **Step 3: Export and write down the numbers.** Export each artboard as PNG into `docs/design/rt/`. Write `docs/design/rt/measurements.md` listing every size, padding, radius, font and color role the canvas uses, in the table style of `docs/design/chat/measurements.md`. These values replace the starting values in Tasks 12 and 13's `ChromeMetrics.RtButton`, `ChromeMetrics.RtModal` and `ChromeType` entries.

- [ ] **Step 4: STOP for Matt.** Show him the canvas (he can open the `.pen`) and the exports. Iterate until he approves. Record the approval in the ledger.

- [ ] **Step 5: Commit**

```bash
git add docs/design/rt && Scripts/checks.sh && git commit -m "design: rt button, menu and modal canvas with reference PNGs

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: The rt button and its popover

The approved values are in `docs/design/rt/measurements.md` ("The legend", "The rt popover") and the reference PNGs beside it (`legend-rt-*.png`, `rt-menu-*.png`). Where this task and the measurements disagree, the measurements win.

**Files:**
- Create: `Sources/Flock/Rt/RtBrand.swift`
- Create: `Sources/Flock/Rt/RtButton.swift` (the legend control)
- Create: `Sources/Flock/Rt/RtPopover.swift`
- Create: `Sources/Flock/Views/PopoverAppearancePin.swift` (lifted from `ChatPopover.swift`)
- Modify: `Sources/Flock/Chat/ChatPopover.swift` (use the lifted pin)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift`, `Sources/Flock/Theme/ChromeTypography.swift`
- Modify: `Sources/Flock/Views/PaneLauncherOverlay.swift` (`NavigatorRoster.rtCd` colours from `RtBrand`)
- Modify: `Sources/Flock/Views/PaneCellView.swift` (`statusChip`)
- Create: `Tests/FlockChromeRender/RtButtonRenderTests.swift`

**Interfaces:**
- Consumes: `RtButtonModel.Appearance` (`absent`, `rest`, `active(count:runner:)`), `RtCommandRow`, `RtRunRow`, `viewModel.rt` (`buttonAppearance(linkedTo:rtInstalled:)`, `commandRows(linkedTo:)`, `runRows(linkedTo:)`, `runner(linkedTo:)`, `open(_:from:)`, `show(_:)`) from Tasks 7-10b.
- Produces: `RtBrand.plum`, `RtBrand.pink`, `RtAvailability.installed`, `RtBadge`, `RtButton`, `RtPopover`, `PopoverAppearancePin`.

- [ ] **Step 1: Write the failing render test**

`Tests/FlockChromeRender/RtButtonRenderTests.swift` renders, in Tokyo Night and Tokyo Night Day, hosted in a real window with a few layout passes and `ChromeType.install()` first (the pattern of `PaneLauncherOverlayTests` and the chat render tests):

1. `RtButton` in each appearance: `.rest`, `.active(count: 1, runner: false)`, `.active(count: 1, runner: true)`, `.active(count: 0, runner: true)`, `.absent`. Assert the plum `#161224` badge is drawn (more than 150 pixels at 2x) for every state but `.absent`, where it is 0; assert rt's pink `#FF6B9D` glyph pixels appear only in the states with `runner: true`.
2. `RtPopover` with four command rows (`RtPopoverModel.commands(hasRunner: true)`), two run rows (`running`, and `finished · exit 0`), folder `~/src/acme`, and the first row previewed as hovered. Assert the popover's `panelBg` ground, the plum badge, and the hovered row's `selectionBg` fill are all present.
3. `NSImage(systemSymbolName:accessibilityDescription:)` resolves for every symbol the two views name: `folder`, `arrow.triangle.branch`, `play`, `waveform.path.ecg`.

With `FLOCK_CHROME_RENDER_DIR` set, each render writes `rt-button-<state>-<theme>.png` and `rt-popover-<theme>.png`.

- [ ] **Step 2: Run it to see it fail**

Run `xcodegen`, then `-scheme FlockChromeRender -only-testing:FlockChromeRender/RtButtonRenderTests`. Expected: compile failure on `RtButton`.

- [ ] **Step 3: Implement**

`Sources/Flock/Rt/RtBrand.swift`:

```swift
import FlockCore
import SwiftUI

/// rt's own colours: pink on plum, as its terminal UI draws itself. The same
/// in every theme.
enum RtBrand {
    static let plum = Color(red: 22 / 255, green: 18 / 255, blue: 36 / 255)
    static let pink = Color(red: 1, green: 107 / 255, blue: 157 / 255)
}

enum RtAvailability {
    /// Read once: every pane's legend asks, and the answer is the startup
    /// PATH's, which does not change for the life of the process.
    static let installed = NavigatorRoster.detected() != nil
}
```

`NavigatorRoster.rtCd` takes `monogramColor: RtBrand.plum, monogramInk: RtBrand.pink`.

`ChromeMetrics` gains `RtButton` and `RtPopover`, every value from the measurements: the badge 16x12 r3; the rest square 27x17 r4; the active pill 18 tall, r4, pad 0/7, gap 5; the divider 1x10; the runner glyph 11; the popover 300 wide, r10, header 41 with pad 12/14 and gap 8, header badge 20x15 r3, folder chip 18 tall r4 pad 3/8 gap 5 with a 10pt glyph; the command band padded 6/8; rows 31 tall, r5, pad 8, gap 9, 14pt glyphs; the RUNS label padded 10/14/6/14 with tracking 0.5; the runs band padded 0/8/8/8; the run dot 7. `ChromeType` gains `rtBadge = inter(8.5, .bold)`, `rtButtonCount = inter(10, .semibold)`, `rtPopoverBadge = inter(10, .bold)`, `rtPopoverFolder = inter(10)`, `rtPopoverRow = inter(12)`, `rtPopoverHint = mono(10)`, `rtPopoverLabel = inter(10, .semibold)`, `rtPopoverState = inter(10)`.

`RtBadge`: the 16x12 plum rounded rectangle with "rt" centred in `rtBadge` pink. The popover's header badge is the same view at its 20x15 size and `rtPopoverBadge` font (give `RtBadge` a size and a font, defaulted to the legend's).

`RtButton` (values in, closures out, so the render tests draw every state without a coordinator):

```swift
struct RtButton: View {
    let theme: Theme
    let paneID: PaneID
    let appearance: RtButtonModel.Appearance
    let onOpenPopover: () -> Void
    let onShowRunner: () -> Void
    ...
}
```

- `.absent` draws nothing.
- `.rest`: one button, the 27x17 `palette.surface0` square with the badge centred; it opens the popover.
- `.active(count, runner)`: one pill (18 tall, `palette.selectionBg`, r4, pad 0/7, gap 5) holding two buttons with no gap of their own beyond the pill's: the badge half (the badge, then the count in `rtButtonCount` `palette.text` when `count > 0`) opens the popover; when `runner` is true, the runner half (a 1x10 `palette.overlay0` divider, then an 11pt `waveform.path.ecg` in `RtBrand.pink`) shows the runner. Each half's hit area covers its own part of the pill edge to edge (a `contentShape`), so the two halves never leave a dead strip between them.
- Accessibility: identifiers `flock.pane.rtButton.<pane>` and `flock.pane.rtRunner.<pane>`; labels "rt", "rt, N running", and "Show runner".

`RtPopover`:

```swift
struct RtPopover: View {
    let theme: Theme
    let folder: String
    let commands: [RtCommandRow]
    let runs: [RtRunRow]
    let onCommand: (RtKind) -> Void
    let onRun: (String) -> Void
    /// Render tests only: the row drawn as hovered without a pointer.
    var previewHoveredCommand: RtKind? = nil
    ...
}
```

It draws exactly the measurements' "The rt popover": the header (badge, spacer, folder chip), the command band (glyph, title, spacer, hint; the hovered row fills `palette.selectionBg` and its glyph turns `theme.accent`), and, only when `runs` is not empty, the RUNS label and the run rows (dot coloured by `RtRunRow.Tone`: `green` running, `red` exited, `overlay0` finished; a running row fills `palette.activeRowBg`). Fill `palette.panelBg`, a 1pt `palette.surface1` border, r10, clipped, like `ChatPopover`. Glyphs per row kind: nav `folder`, glitter `arrow.triangle.branch`, run `play`, runner `waveform.path.ecg`. The folder chip's glyph is `folder`. The folder shows the home folder as `~` (share the logic `RtItem.modalTitle(home:)` uses; lift it to a small `RtPaths.tilde(_:home:)` in FlockCore if that is the cleanest way to share it, with one test).

`PopoverAppearancePin`: move `ChatPopoverAppearancePin` out of `ChatPopover.swift` unchanged apart from its name, into `Sources/Flock/Views/PopoverAppearancePin.swift`, make it internal, and use it from both popovers (`isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)`).

In `PaneCellView.statusChip`, right after the chat button:

```swift
            if chatButtonAppearance != .absent { chatButton }
            rtButton
```

and add:

```swift
    @State private var isRtPopoverPresented = false

    private var rtButton: some View {
        RtButton(
            theme: theme, paneID: pane.paneID,
            appearance: viewModel.rt.buttonAppearance(linkedTo: pane.terminalID, rtInstalled: RtAvailability.installed),
            onOpenPopover: { isRtPopoverPresented = true },
            onShowRunner: { showRunner() }
        )
        .popover(isPresented: $isRtPopoverPresented, arrowEdge: .bottom) { rtPopover }
    }

    @ViewBuilder
    private var rtPopover: some View {
        if let terminal = pane.terminalID {
            RtPopover(
                theme: theme, folder: <the pane's cwd with home as ~>,
                commands: viewModel.rt.commandRows(linkedTo: terminal),
                runs: viewModel.rt.runRows(linkedTo: terminal),
                onCommand: { kind in openRt(kind) },
                onRun: { id in showRtItem(id) }
            )
        }
    }

    /// The pane is read again at the click, so the command opens at the
    /// folder the pane is in now, not the one it was in when this cell drew.
    private func openRt(_ kind: RtKind) {
        isRtPopoverPresented = false
        let current = viewModel.fullModel?.panes[pane.paneID] ?? pane
        Task { await viewModel.rt.open(kind, from: current) }
    }

    private func showRtItem(_ id: String) {
        isRtPopoverPresented = false
        Task { await viewModel.rt.show(id) }
    }

    private func showRunner() {
        guard let terminal = pane.terminalID, let runner = viewModel.rt.runner(linkedTo: terminal) else { return }
        Task { await viewModel.rt.show(runner.id) }
    }
```

The popover modifier sits on `RtButton` as a whole, never inside one of its branches, for the reason the chat button's comment gives: a flip between `.rest` and `.active` must not tear down and re-present it.

- [ ] **Step 4: Run it to see it pass, then look**

Run `RtButtonRenderTests` with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=<dir>`. Expected: pass. Open every PNG it wrote next to `docs/design/rt/legend-rt-*.png` and `rt-menu-*.png` and compare feature by feature (badge, square, pill, count, divider, glyph, spacing to chat; popover header, rows, hint, RUNS, dots). Any unexplained difference is a defect: fix it before committing. Then run the whole `FlockChromeRender` suite (the chat popover's tests must still pass after the pin moves) and the whole `FlockCoreTests`.

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "legend: an rt button right of chat, with a runner half and a popover

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: The modal

The approved values are in `docs/design/rt/measurements.md` ("The modal") and `modal-nav-*.png`, `modal-strips-*.png`, `modal-service-*.png`. Where this task and the measurements disagree, the measurements win.

**Files:**
- Create: `Sources/Flock/Rt/RtModalView.swift` (overlay, box, title row, strip)
- Create: `Sources/Flock/Rt/RtModalPane.swift` (the one pane on its ghostty surface)
- Create: `Sources/Flock/Rt/RtModalKeyMonitor.swift`
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift`, `Sources/Flock/Theme/ChromeTypography.swift`
- Modify: `Sources/Flock/Views/MainWindow.swift` (the tab area's `VStack`)
- Modify: `Sources/Flock/Views/PaneCanvas.swift` (`isFocused`)
- Modify: `Sources/Flock/FlockApp.swift` (the `FocusedPaneCommand` and `PaneDirectionCommand` buttons)
- Create: `Tests/FlockChromeRender/RtModalChromeRenderTests.swift`

**Interfaces:**
- Consumes: `viewModel.rt` (`modal`, `modalItem`, `closeModal`, `backToBoard`), `viewModel.fullModel`, `viewModel.canvasFocusedPaneID`, `RtModalKey`, `RtStrip.text`, `RtItem.modalTitle(home:)`, `GhosttyPaneTerminalView`, `attachPane`/`detachPane`/`ghosttySurface(for:)`, `ChromeRoles.isLight(panelBg:)`.
- Produces: `RtModalView`, `RtModalTitleRow`, `RtModalStripView`, `RtModalPane`, `RtModalKeyMonitor`.

- [ ] **Step 1: Write the failing render test**

`Tests/FlockChromeRender/RtModalChromeRenderTests.swift`, both themes, hosted as in Task 12: `RtModalTitleRow` without and with "← runner" (assert something drew, and with the back control that `theme.accent` pixels appear), and `RtModalStripView` for `.exited(1)` (assert `palette.red` pixels) and `.finished(0)`. With `FLOCK_CHROME_RENDER_DIR` set, write `rt-modal-<part>-<theme>.png`.

- [ ] **Step 2: Run it to see it fail**

Expected: compile failure on `RtModalTitleRow`.

- [ ] **Step 3: Implement**

`ChromeMetrics.RtModal`, from the measurements: size fraction 0.8; corner radius 8; backdrop 0.45 in a dark theme and 0.30 in a light one; shadow black at 0.35, radius 12, y 8; title row 28 tall, pad 0/12, gap 8; the back divider 1x12; the close glyph 12; strip 26 tall, pad 0/12; the pane inset 6. `ChromeType`: `rtModalTitle = inter(11.5, .semibold)`, `rtModalBack = inter(11, .medium)`, `rtModalStrip = inter(11, .medium)`.

**Placement.** The overlay covers the tab area only: in `MainWindow`, attach it to the `VStack` holding `TabStrip` and `PaneCanvas` (never the `HStack` with the rail, never the title bar or banners), so the sidebar stays clear and undimmed:

```swift
                    VStack(spacing: 0) {
                        TabStrip(...)
                        PaneCanvas(...)
                    }
                    .overlay { RtModalView(theme: theme, viewModel: viewModel) }
```

The modal opens from a pane's rt button, which the All Workspaces grid does not show, so the grid branch gets no overlay.

**`RtModalView`:** when `viewModel.rt.modal` and `modalItem` are set, a `GeometryReader` over the tab area: the backdrop (black at the theme's opacity, `ChromeRoles.isLight(panelBg:)` choosing which) that closes the modal on a tap, and centred on it the box at 0.8 of the area on each axis. The box is a `VStack(spacing: 0)`: `RtModalTitleRow`, then the pane (`RtModalPane`, inset 6), then `RtModalStripView` when the item has a strip. Box fill `theme.pane`, 1pt `theme.paneBorder`, r8, clipped, the shadow. `RtModalKeyMonitor` sits in its background (⌘W closes; any plain key closes while a strip is up; other ⌘ keys pass). `Sources/Flock/Rt/RtModalKeyMonitor.swift`:

```swift
import AppKit
import FlockCore
import SwiftUI

/// Takes ⌘W, and any plain key while a strip is up, before the terminal or the
/// window's own Close sees it. Installed while the modal is on screen: the view
/// leaving its window removes the monitor.
struct RtModalKeyMonitor: NSViewRepresentable {
    let stripShown: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.stripShown = stripShown
        view.onClose = onClose
    }

    final class MonitorView: NSView {
        var stripShown = false
        var onClose: () -> Void = {}
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                let flags = event.modifierFlags
                let decision = RtModalKey.decide(
                    characters: event.charactersIgnoringModifiers,
                    command: flags.contains(.command), shift: flags.contains(.shift),
                    option: flags.contains(.option), control: flags.contains(.control),
                    stripShown: self.stripShown
                )
                guard decision == .close else { return event }
                self.onClose()
                return nil
            }
        }
    }
}
```

**`RtModalTitleRow(theme:title:showsBackToRunner:onBack:onClose:)`:** 28 tall, fill `theme.chrome`, pad 0/12, gap 8. With `showsBackToRunner`, it leads with a "← runner" button (`rtModalBack`, `theme.accent`) and a 1x12 `theme.rule` divider; then the title (`rtModalTitle`, `theme.textStrong`, one line, middle truncation), a spacer, and the close button (`xmark` at 12 in `theme.textDim`). Identifiers: `flock.rt.modal.backToRunner`, `flock.rt.modal.close`.

**`RtModalStripView(theme:strip:)`:** 26 tall, fill `theme.chrome`, a 1pt `theme.rule` line along its top edge, pad 0/12, `strip.text` in `rtModalStrip`, `palette.red` for `.exited`, `theme.textStrong` for `.finished`. Identifier `flock.rt.modal.strip`.

**The pane.** Every hidden rt tab holds one pane, so the modal shows one surface, with no tab strip and no split layout. The pane is the shown tab's: `viewModel.fullModel?.panes.values.first { $0.tabID == modal.shownTabID }?.paneID`, falling back to `item.firstPaneID` until the model has the tab. `RtModalPane` hosts it on its ghostty surface, sized by `SurfaceGrid.fit` to the cell metrics of `TerminalTextSizeStore` for the space it has, with `isFocused` true unless a strip is up. `Sources/Flock/Rt/RtModalPane.swift` (its caller computes `grid` and `surfaceSize` from a `GeometryReader` the way `PaneCanvas` does for a cell, with `PaneBox.frame` and `SurfaceGrid.fit`):

```swift
import FlockCore
import SwiftUI

/// One hidden pane on its ghostty surface. It attaches and parks like a
/// canvas cell, through the view model's per-pane chain.
struct RtModalPane: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let paneID: PaneID
    let grid: PTYSize
    let surfaceSize: CGSize
    let fontSizePoints: Double
    let isFocused: Bool
    let onFocus: () -> Void

    @Environment(OptionAsAltStore.self) private var optionAsAltStore
    @State private var surface: (any GhosttyPaneSurface)?

    init(
        theme: Theme, viewModel: SessionViewModel, paneID: PaneID, grid: PTYSize, surfaceSize: CGSize,
        fontSizePoints: Double, isFocused: Bool, onFocus: @escaping () -> Void
    ) {
        self.theme = theme
        self.viewModel = viewModel
        self.paneID = paneID
        self.grid = grid
        self.surfaceSize = surfaceSize
        self.fontSizePoints = fontSizePoints
        self.isFocused = isFocused
        self.onFocus = onFocus
        _surface = State(initialValue: viewModel.ghosttySurface(for: paneID))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.terminalGround
            if let surface {
                GhosttyPaneTerminalView(
                    surface: surface, grid: grid, theme: theme, isFocused: isFocused,
                    fontSizePoints: fontSizePoints, optionAsAlt: optionAsAltStore.active,
                    rearrangeActive: false, paneDragInProgress: false, isPristineLauncherPane: false,
                    editorIsOpen: false, onPrimaryClick: onFocus, menuProvider: { nil }, onBodyDragBegan: { _ in }
                )
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
                .opacity(surface.hasFirstFrame ? 1 : 0)
            }
        }
        .task(id: paneID) { surface = await viewModel.attachPane(paneID) }
        .onDisappear { Task { await viewModel.detachPane(paneID) } }
    }
}
```

**Canvas focus and commands.** In `PaneCanvas`, the cell's focus reads the canvas's own answer:

```swift
                                isFocused: pane.paneID == viewModel.canvasFocusedPaneID,
```

and the comment above it says the modal withholds canvas focus while it is up (keep the existing reasons for not reading `layout.focusedPaneID` or `model.focusedPaneID`). In `FlockApp`, the `FocusedPaneCommand` buttons (Split Right, Split Down, Close Pane) aim at the canvas's pane, so ⌘⇧X under the modal cannot close the linked pane and everything linked to it:

```swift
                    Button(command.title) {
                        guard let pane = viewModel.canvasFocusedPaneID else { return }
                        Task { await command.action.perform(paneID: pane, on: viewModel) }
                    }
                    .keyboardShortcut(command.shortcut)
                    .disabled(viewModel.canvasFocusedPaneID == nil)
```

The `PaneDirectionCommand` buttons (move and swap the focused pane) act on herdr's focused pane, which the modal does not hold, so append `|| viewModel.rt.modal != nil` to their `.disabled(...)` condition.

- [ ] **Step 4: Run it to see it pass, then look**

Run `RtModalChromeRenderTests` with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=<dir>`. Expected: pass. Compare each PNG with `docs/design/rt/modal-*.png` feature by feature; fix any unexplained difference. Then the whole `FlockChromeRender` and `FlockCoreTests`.

The modal's placement over the tab area and its terminal are live views the render suite does not host; they are verified by hand (Task 14).

- [ ] **Step 5: Commit**

```bash
git add -A && Scripts/checks.sh && git commit -m "rt: the modal hosts a hidden pane over the tab area, with its strips and keys

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Hand it to Matt (CHECKPOINT)

**Files:** none new.

- [ ] **Step 1: Full gates.** Run the whole `FlockCoreTests`, the whole `FlockChromeRender`, and `Scripts/checks.sh`. All must pass. Record counts.

- [ ] **Step 2: Dev build into the main checkout's watched folder.**

```bash
Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev
```

Tell Matt to click the "New build · Restart" pill in Flock Dev. Never quit or launch his apps yourself.

- [ ] **Step 3: Hand-test list for Matt** (clicks and focus count as verified only by his hand):
  1. The rt button sits right of chat on every pane; rest looks quiet, active shows the running rt run items' count, and a live runner adds the pulse half.
  2. rt popover, Browse files (nav): the modal opens at the pane's folder; opening a file works; Esc quits and the modal closes.
  3. nav, "cd here" on a shell pane: the pane cds. On a claude pane: a split opens at the folder.
  4. glitter: opens, quits, modal closes. In a folder that is not a repo: exited strip with rt's message; any key closes.
  5. run: pick a test script; it runs in the modal; the finished strip shows the exit code. Pick a dev server; ⌘W; the rt button counts 1; the popover lists it under RUNS as running; clicking it shows it live.
  6. run, "Launch all" with two queued scripts: a runner board seeded with both opens in the modal (needs rt with queued launches opening a board).
  6b. run, a saved preset: its board shows in the modal; ⌘W keeps it running and counted; closing the linked pane stops it.
  7. runner: the board opens; ⌘W hides it; the rt button gains its pulse half; clicking the pulse shows the runner; `f` on a service opens its terminal with `← runner`; back returns to the board.
  8. Close the pane that owns a runner: the runner and its services stop (check with `rt runner` state or the process list), no prompt.
  9. Restart Flock Dev with a runner and a run item going: both come back on the same pane.
  10. Drag a pane with a runner to another workspace: the runner stays linked.
  11. Click outside the modal: it closes by the same rules as ⌘W.
  12. The modal covers the tab strip and panes only: the sidebar stays clear and undimmed, and clicking a workspace in it still works.

- [ ] **Step 4: Fold feedback in.** Each fix is its own red-green-commit cycle, then rerun the gates and `dev-build.sh`.

- [ ] **Step 5: Finish the branch.** Rebase onto the current `main` first (it moves while this runs; `PaneCellView` is the likeliest conflict), rerun the gates, then superpowers:finishing-a-development-branch (a PR to m4ttstack/flock; wait for CodeRabbit and CI per Matt's rules; merge only on his confirmation).
