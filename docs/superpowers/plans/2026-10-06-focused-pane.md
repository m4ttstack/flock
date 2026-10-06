# Focused Pane and Overview Identity Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** opening a card from Overview shows that one pane, live, in a focused view whose only navigation is back to Overview; and Overview wears Arrange's identity colours.

**Architecture:** the focused pane is grid state in FlockCore (`AllWorkspacesGridState.focused`), routed by the existing `JumpNavigator`, and drawn by the main window's own `PaneCanvas` in a new solo mode, which shows one pane through the canvas's existing `CanvasComposition.zoomed` and tells its `PaneCellView` (through an environment value) not to move herdr's focus or show the zoom badge. No second terminal view. Identity grouping is a drawing change in `MissionControlView` and `MissionCardView`, using the identity colours both views already resolve.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, xcodegen. macOS 26 SDK.

**Spec:** `docs/superpowers/specs/2026-10-06-mission-control-design.md`, sections "Focused pane" and "A card" → "Identity grouping". Visual references: boards `11 · Overview · Focused pane` and `05c · Overview · identity groups` in `docs/design/workspaces/flock-workspaces.pen` (open copy at `~/Documents/flock workspaces.pen`; pencil MCP tools only, never `Read`). PNG exports of earlier boards are in `build/boards/`.

## Global Constraints

- Public repo: no employer, customer, ticket id or private host anywhere, commit messages included. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration, no history.
- Tests are hermetic: no rt, herdr, herdr-chat or deck processes, no `~/.mattstack`, no network, no real UserDefaults, no reading real git checkouts.
- Derived data `-derivedDataPath build/dd`. Run only the tests for what a task touches.
- New files: `xcodegen` before building. After `git add`, `Scripts/checks.sh`.
- The worktree guard refuses complex shell commands that mention git: run git as plain, separate calls. Commit messages end with a blank line then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- UI is not done until rendered in a dark and a light theme and looked at.
- Never quit, kill or launch Flock or Flock Dev; never touch herdr; never run `Scripts/e2e.sh`.
- Reuse the main window's code (`PaneCanvas`, `PaneCellView`, `RtModalView`, the grid header metrics, `GridControlButton`, `StatusDot`, `MissionAge`, the identity colour helpers). Do not write a second terminal view, a second identity resolver or a second board builder.
- In the focused view nothing calls `tab.focus`, `pane.focus` or `workspace.focus` on herdr.

## Review Focus

1. A pane that closes while it is focused: the view returns to Overview, never shows an empty canvas (Task 1 test, Task 3 wiring).
2. Esc while focused reaches the terminal and does not close the view (Task 1 `EscapeRoute` test).
3. ⌘J in the focused view with no cards left does nothing (menu disabled) and never closes the view (Task 3).
4. Clicking the focused pane's title or surface never moves herdr's focus (Task 2 environment value; Task 3 test with a recording client sees no focus calls).
5. Leaving the view (⇧⌘R) while focused and opening it again shows Overview's lanes, not a stale focused pane (Task 1 test).

---

## File Structure

- Modify `Sources/FlockCore/Grid/AllWorkspacesGrid.swift`: `AllWorkspacesGridState.focused`, `focus(pane:)`, `unfocus()`, `close()` clears it, `reconcile(livePanes:)`; `EscapeRoute.route` gains `gridFocusesPane`.
- Modify `Sources/FlockCore/ViewModels/SessionViewModel.swift`: `focusInOverview(pane:)`, `oldestAttentionPane`.
- Modify `Sources/Flock/Drag/DragCoordinator+Grid.swift`, `Sources/Flock/Drag/DragCoordinator.swift` (Esc route call).
- Modify `Sources/Flock/Views/PaneCanvas.swift`: `solo: PaneID?`.
- Modify `Sources/Flock/Views/PaneCellView.swift`: reads `\.paneCellRole`.
- Create `Sources/Flock/Views/MissionControl/FocusedPaneView.swift`: header plus solo canvas.
- Modify `Sources/Flock/Views/AllWorkspacesGrid.swift` (draws `FocusedPaneView` when focused), `Sources/Flock/Menus/JumpNavigator.swift`, `Sources/Flock/FlockApp.swift` (menu enablement).
- Modify `Sources/Flock/Views/MissionControl/MissionControlView.swift`, `MissionCardView.swift` (identity groups).
- Tests: `Tests/FlockCoreTests/AllWorkspacesGridTests.swift` (exists), `Tests/FlockCoreTests/MissionJumpTests.swift` (exists), `Tests/FlockChromeRender/ChromeRenderTests.swift`.

---

### Task 1: Focused pane state and Esc routing (FlockCore)

**Files:**
- Modify: `Sources/FlockCore/Grid/AllWorkspacesGrid.swift`
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift`
- Test: `Tests/FlockCoreTests/AllWorkspacesGridTests.swift`, `Tests/FlockCoreTests/MissionJumpTests.swift`

**Interfaces:**
- Produces: `AllWorkspacesGridState.focused: PaneID?` (public private(set)), `mutating func focus(pane: PaneID)` (no-op unless shown), `mutating func unfocus()`, `mutating func reconcile(livePanes: Set<PaneID>)` (unfocuses when the focused pane is gone). `close()` also clears `focused`. `EscapeRoute.route(dragIdle:gridShown:gridFocusesPane:railTakesEscape:)`. `SessionViewModel.focusInOverview(pane: PaneID) -> Bool` (dismisses the pane's attention card, returns whether the pane exists, makes no herdr call), `SessionViewModel.oldestAttentionPane: PaneID?` (`attentionToasts.toasts.last?.paneID`).

- [ ] **Step 1: Write the failing tests**

In `AllWorkspacesGridTests.swift` (add to the existing test class; read the file first for its helpers):

```swift
    func testAPaneIsFocusedOnlyWhileTheGridIsShown() {
        var grid = AllWorkspacesGridState()
        grid.focus(pane: PaneID(rawValue: "p1"))
        XCTAssertNil(grid.focused, "nothing to focus inside a closed view")
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        XCTAssertEqual(grid.focused, PaneID(rawValue: "p1"))
        grid.unfocus()
        XCTAssertNil(grid.focused)
    }

    func testClosingTheViewForgetsTheFocusedPane() {
        var grid = AllWorkspacesGridState()
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        grid.close()
        grid.open()
        XCTAssertNil(grid.focused, "reopening shows Overview's lanes")
    }

    func testAFocusedPaneThatClosesReturnsToOverview() {
        var grid = AllWorkspacesGridState()
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        grid.reconcile(livePanes: [PaneID(rawValue: "p1"), PaneID(rawValue: "p2")])
        XCTAssertEqual(grid.focused, PaneID(rawValue: "p1"))
        grid.reconcile(livePanes: [PaneID(rawValue: "p2")])
        XCTAssertNil(grid.focused)
        XCTAssertTrue(grid.isShown, "the view stays open on Overview")
    }

    func testEscBelongsToTheTerminalWhileAPaneIsFocused() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridFocusesPane: true, railTakesEscape: false), .focusedView)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridFocusesPane: false, railTakesEscape: false), .grid)
        XCTAssertEqual(EscapeRoute.route(dragIdle: false, gridShown: true, gridFocusesPane: true, railTakesEscape: false), .drag)
    }
```

Update every existing `EscapeRoute.route(...)` call in tests to pass `gridFocusesPane: false` (grep `EscapeRoute.route` in Tests).

In `MissionJumpTests.swift` (it has `RecordingClient`, `Clock` and `model(_:)`):

```swift
    func testFocusingInOverviewDismissesTheCardAndNeverMovesHerdr() async {
        let clock = Clock()
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client, now: { clock.now })
        viewModel.update(model: model([.working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked]), connection: .live)
        let pane = PaneID(rawValue: "w2:t1:p1")
        XCTAssertEqual(viewModel.oldestAttentionPane, pane)
        XCTAssertTrue(viewModel.focusInOverview(pane: pane))
        XCTAssertNil(viewModel.attentionToasts.toast(pane: pane))
        XCTAssertNil(viewModel.oldestAttentionPane)
        let calls = await client.calls
        XCTAssertEqual(calls, [], "focusing in Overview sends herdr nothing")
        XCTAssertFalse(viewModel.focusInOverview(pane: PaneID(rawValue: "gone")))
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/AllWorkspacesGridTests -only-testing:FlockCoreTests/MissionJumpTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -25`
Expected: build failure, `value of type 'AllWorkspacesGridState' has no member 'focus'`.

- [ ] **Step 3: Implement**

In `AllWorkspacesGridState`:

```swift
    /// The pane Overview has opened in its focused view. Belongs to this
    /// opening of the view: a closed view forgets it.
    public private(set) var focused: PaneID?

    public mutating func focus(pane: PaneID) {
        guard isShown else { return }
        focused = pane
    }

    public mutating func unfocus() {
        focused = nil
    }

    /// A focused pane that herdr no longer reports leaves the view on
    /// Overview rather than on an empty canvas.
    public mutating func reconcile(livePanes: Set<PaneID>) {
        if let focused, !livePanes.contains(focused) { self.focused = nil }
    }
```

and in `close()` add `focused = nil`.

`EscapeRoute`:

```swift
    /// A live drag owns Esc as its cancel. A pane focused inside the grid is
    /// a live terminal, and Esc is its key. Otherwise the grid covers the
    /// rail, so it outranks the rail's selection, and what is left reaches
    /// the focused terminal.
    public static func route(dragIdle: Bool, gridShown: Bool, gridFocusesPane: Bool, railTakesEscape: Bool) -> EscapeRoute {
        guard dragIdle else { return .drag }
        if gridShown { return gridFocusesPane ? .focusedView : .grid }
        return railTakesEscape ? .railSelection : .focusedView
    }
```

`SessionViewModel` (beside `dismissAttentionToast(pane:)`):

```swift
    /// Overview's focused view: the card is dismissed as a jump would, but
    /// herdr's focus stays where the main window left it.
    @discardableResult
    public func focusInOverview(pane: PaneID) -> Bool {
        guard model?.panes[pane] != nil else { return false }
        attentionToasts.dismiss(pane: pane)
        return true
    }

    /// The card ⌘J takes next when every card is drawn.
    public var oldestAttentionPane: PaneID? { attentionToasts.toasts.last?.paneID }
```

Update the one app call site of `EscapeRoute.route` (`Sources/Flock/Drag/DragCoordinator.swift`, in the Esc monitor) to pass `gridFocusesPane: grid.focused != nil`.

- [ ] **Step 4: Run to see them pass**

Same command. Expected: `** TEST SUCCEEDED **`. Also build the app: `xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | tail -5`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Grid/AllWorkspacesGrid.swift Sources/FlockCore/ViewModels/SessionViewModel.swift Sources/Flock/Drag/DragCoordinator.swift Tests/FlockCoreTests
Scripts/checks.sh
git commit -m "all workspaces: a pane focused inside Overview, and Esc left to its terminal"
```

### Task 2: PaneCanvas solo mode and the cell role

**Files:**
- Modify: `Sources/Flock/Views/PaneCanvas.swift`, `Sources/Flock/Views/PaneCellView.swift`
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (one render test, beside the canvas zoom tests; grep `zoom` there for the existing harness pattern)

**Interfaces:**
- Produces: `PaneCanvas(theme:viewModel:layout:solo:)` with `var solo: PaneID? = nil`; an environment value `\.paneCellRole: PaneCellRole` with `enum PaneCellRole { case canvas, solo }` (default `.canvas`).

Behaviour of `solo`:
- composition is `.zoomed(solo)` regardless of the layout's own zoom (so only that pane is drawn, at the full canvas, through the existing zoom geometry);
- `isFocused` is `pane.paneID == solo` (the solo pane holds the keyboard; `canvasFocusedPaneID` is the main window's and is not consulted);
- `isZoomed` is false (no zoom badge: there is no zoom to leave);
- no `DropzoneOverlay`, no divider handles, and no `canvasReporter` (the focused view is never a drop target and must not publish canvas frames the drag coordinator would hit-test against);
- the cells get `.environment(\.paneCellRole, .solo)`.

In `PaneCellView`, read `@Environment(\.paneCellRole) private var role`. Every place that calls `viewModel.jumpToHerdr(pane:)` (the title click's `.select`, the surface's `onPrimaryClick`, and the third call site; grep `jumpToHerdr(pane` in the file) skips the herdr call when `role == .solo`. A solo cell's title click and surface click still give its terminal the keyboard (it is already `isFocused`). Keep the legend controls (mouse badge, chat button, rt button) exactly as they are. Do not add other behaviour switches.

- [ ] **Step 1: Write the failing render test** — render a `PaneCanvas(theme:viewModel:layout:solo:)` for a two-pane fixture tab (use the harness that renders the canvas today) with `solo` set to the second pane, in tokyo-night and tokyo-night-day, writing `focused-canvas-dark.png` / `focused-canvas-light.png` under `FLOCK_GRID_RENDER_DIR`. Assert: the canvas publishes one cell frame (the solo pane's) filling the canvas within a cell's rounding, and no zoom badge element (`flock.canvas.zoom` style identifier; grep the file for how zoom badge tests find it).
- [ ] **Step 2: Run to see it fail** (`solo` is not a parameter).
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run it, and the existing canvas and zoom render tests** (`-only-testing:FlockChromeRender/ChromeRenderTests`). Look at both PNGs: the pane fills the canvas, its legend shows its controls top right, no badge.
- [ ] **Step 5: Commit** — `"pane canvas: a solo mode that shows one pane and leaves herdr's focus alone"`.

### Task 3: The focused view, wired into Overview

**Files:**
- Create: `Sources/Flock/Views/MissionControl/FocusedPaneView.swift`
- Modify: `Sources/Flock/Views/AllWorkspacesGrid.swift`, `Sources/Flock/Menus/JumpNavigator.swift`, `Sources/Flock/Drag/DragCoordinator+Grid.swift`, `Sources/Flock/FlockApp.swift`, `Sources/Flock/Theme/ChromeMetrics.swift` (only if a new metric is needed)
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift`

**Interfaces:**
- Consumes: Task 1 (`grid.focused`, `focus(pane:)`, `unfocus()`, `reconcile(livePanes:)`, `focusInOverview(pane:)`, `oldestAttentionPane`), Task 2 (`PaneCanvas(... solo:)`).
- Produces: `DragCoordinator.focusGridPane(_:)`, `unfocusGridPane()`, `var gridFocusedPane: PaneID?`; `JumpNavigator.isFocusedInOverview`.

Rules (the spec's "Focused pane"):

- `JumpNavigator.open(pane:)`: when `isInMissionControl` (grid shown, Overview drawn), `viewModel.focusInOverview(pane:)`, set `mode.missionSelection = pane`, `drag.focusGridPane(pane)`; never `closeGrid()`, never a herdr jump, no `recordJump`. Outside Overview it behaves as today.
- `JumpNavigator.openOldest()`: when `isInMissionControl` (lanes or focused), open `viewModel.oldestAttentionPane` the same way (no-op when nil). Outside Overview, as today.
- `JumpNavigator.back()`: when a pane is focused, `drag.unfocusGridPane()` (Overview's lanes reappear with `mode.missionSelection` already on that card). Otherwise as today. `backTarget` is `.missionControl` while focused, so the View menu's Jump Back is enabled there.
- `currentPlace` while focused is `.missionControl`.
- The View menu's "Open Oldest Notification" stays disabled when the stack is empty, so ⌘J with no cards left does nothing.
- `AllWorkspacesGrid`: in Overview, draw `FocusedPaneView` instead of `MissionControlView` while `drag.gridFocusedPane != nil`. Call `drag.updateGrid { $0.reconcile(livePanes:) }` on change of the model's pane ids. The mode toggle header is replaced by the focused view's own header while focused (the grid's header row is not drawn twice).
- `FocusedPaneView(theme:viewModel:pane:)`:
  - Header at `ChromeMetrics.Grid.headerHeight`, `ChromeMetrics.Grid.headerHorizontalPadding`, chrome ground, rule below, `WindowDragExclusion()` background, like the grid header.
  - Left: a "‹ Overview" `GridControlButton` (rounded, `tabRest` rest fill, rule outline, `textStrong`) calling the navigator's `back()`; a separator; the identity square (12pt, radius 3) in the workspace's identity colour (reuse the identity colour helper Overview uses; extract it to one shared function if it is currently private to one view, rather than copying it); `workspace › tab` with the workspace name in its identity colour (herds neutral) and the tab via `TabTitle.resolve`; the status dot and `MissionAge`-formatted state and age in the status hue (age from `viewModel.statusHistory.age(of:at:)`).
  - Right: "N more need you" (dot in the blocked hue, `textDim`) when `viewModel.attentionToasts.toasts.count > 0`; a separator; `⌘J next  ·  ⇧⌘J overview` in `ChromeType.gridHint`.
  - Body: `PaneCanvas(theme:viewModel:layout: viewModel.model?.layouts[tab], solo: pane)`, with `.overlay { RtModalView(theme:viewModel:) }` so the pane's rt button works as in the main window. The chat button needs nothing extra.
  - Accessibility identifiers: `flock.focused.back`, `flock.focused.header`.
- Key routing: `MissionKeyMonitor` (arrows and Return) must not be installed while focused (it lives in `MissionControlView`, which is not mounted then; confirm). The pane's surface must take first responder when the focused view appears, through the same mechanism the main canvas uses for its focused cell (see `FirstResponderClaim`); add a render-harness test like the existing "mission control takes arrows from a terminal" test that, with the focused view shown over a terminal holding the keyboard, a keyDown reaches the solo pane's surface and Esc does not close the grid.

- [ ] **Step 1: Write the failing render tests** in `ChromeRenderTests` beside the mission-control tests:
  - `testFocusedPaneRendersInDarkAndLight`: open the grid in Overview, raise a blocked Needs-you card for a fixture pane, open it through `JumpNavigator(...).open(pane:)`, settle, write `focused-dark.png`/`focused-light.png`; assert `drag.gridFocusedPane` is that pane, the grid is still shown, the card is gone from the stack, and the recording client saw no `tab.focus`/`pane.focus`/`workspace.focus`.
  - `testBackFromTheFocusedPaneSelectsItsCard`: after the above, `navigator.back()`; assert `gridFocusedPane == nil`, the grid is shown in Overview, `mode.missionSelection` is the pane.
  - `testJInTheFocusedViewOpensTheNextCard`: two cards; open the first; `navigator.openOldest()`; assert the focused pane is the second.
  - `testEscInTheFocusedViewReachesTheTerminal` (the key routing test above).
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `-only-testing:FlockChromeRender/ChromeRenderTests` plus `PaletteShortcutTests` and `PaletteCatalogTests`. Render with `TEST_RUNNER_FLOCK_GRID_RENDER_DIR` and look at `focused-dark.png` and `focused-light.png` next to board 11 (`build/boards/` has no export of board 11; ask the controller for one if needed). Check: the back button reads as the one way out; the identity square and name; the state and age in the status hue; the pane's legend controls at its top right; no tab strip, rail or dock.
- [ ] **Step 5: Commit** — `"overview: open a card as a focused pane, with Overview the only way out"`.

### Task 4: Overview identity groups

**Files:**
- Modify: `Sources/Flock/Views/MissionControl/MissionControlView.swift`, `Sources/Flock/Views/MissionControl/MissionCardView.swift`, `Sources/Flock/Theme/ChromeMetrics.swift` (`MissionControl` group metrics)
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (`testMissionControlRendersInDarkAndLight`)

Per the spec's "Identity grouping" and board 05c:

- Working: each `MissionGroup` draws as a group: identity colour at `ChromeMetrics.Grid.islandTint` (the same strength as an Arrange island), corner radius 10, padding 10, 10pt between cards. Its label is the identity square (10pt, radius 3) and the workspace name in its identity colour, semibold, no rule. A herd's group uses the neutral `textLabel` colour for tint, square and name, as Arrange does.
- Needs you and Cooling down cards (`showsWorkspace == true`): the top line leads with the identity square (9pt, radius 2.5), then the status dot, then the workspace name in its identity colour and `› tab` in `textLabel`. Working cards keep their tab-only top line.
- Status colours unchanged; identity never fills a card.
- Reuse the identity colour resolution Overview already has (`identityColor(_:sections:)`), shared with Task 3's header (one function).

- [ ] **Step 1: Extend the render test**: sample a Working group's ground beside its first card and assert it is not the lane's `pane` colour (the group is tinted); sample a Needs-you card's identity square and assert it is the workspace's identity colour.
- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `testMissionControlRendersInDarkAndLight` and the hover render tests; look at `mission-dark.png` and `mission-light.png` next to board 05c; the tints should read as Arrange's islands, quiet in light.
- [ ] **Step 5: Commit** — `"overview: workspace groups and cards wear Arrange's identity colours"`.

### Task 5: Hand off

- [ ] Run `xcodebuild test -scheme Flock ... -only-testing:FlockCoreTests/AllWorkspacesGridTests -only-testing:FlockCoreTests/MissionJumpTests -only-testing:FlockCoreTests/AllWorkspacesModeTests`, `-scheme FlockChromeRender -only-testing:FlockChromeRender/ChromeRenderTests -only-testing:FlockChromeRender/PaletteShortcutTests -only-testing:FlockChromeRender/PaletteCatalogTests -only-testing:FlockChromeRender/GridControlAppearanceTests -only-testing:FlockChromeRender/GridControlHoverRenderTests`, and `Scripts/checks.sh`.
- [ ] Copy `~/Documents/flock workspaces.pen` over `docs/design/workspaces/flock-workspaces.pen` once Matt has saved it, and commit (`"design: focused pane and identity group boards"`).
- [ ] `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev`, then tell Matt to click "New build · Restart" and try: a card click opens the focused pane; typing reaches it; its rt and chat buttons; ⌘J next; ⇧⌘J and "‹ Overview" back with the card selected; Esc in the terminal; leaving Overview returns the main window where it was.
