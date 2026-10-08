# Pane Launcher At An Empty Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The harness launcher shows whenever a pane's shell sits at an empty prompt and hides whenever it does not, with ⌘1..⌘3 launching into it from a cold app launch.

**Architecture:** `PaneLauncherRegistry` (FlockCore) becomes a pure, clock-injected state machine over three live signals: the active screen's non-empty row count from libghostty, keystrokes from the surface view, and herdr's `pane.process_info` answer. `SessionViewModel` feeds it and owns one poll task per candidate pane. The View menu's digit items decide at press time whether to launch or switch views, so no key equivalent is ever toggled.

**Tech Stack:** Swift, SwiftUI, AppKit, libghostty (`GhosttyKit.xcframework`), XCTest, xcodegen, herdr's JSON socket API.

**Spec:** `docs/superpowers/specs/2026-10-07-pane-launcher-at-prompt-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host, ticket id or private workspace link anywhere. `Scripts/checks.sh` enforces a word list over tracked files and the last 30 commit messages.
- No em or en dashes anywhere (`checks.sh` fails on them). Use plain hyphens, colons or new sentences.
- Comments state constraints the code cannot show. No narration, no decision history, no "// added for ...".
- Every build and test run uses a scratch `-derivedDataPath` inside the worktree's `build/` directory, never one under a path containing `GitHub`.
- Run `xcodegen` after adding or removing any source file. Run `Scripts/checks.sh` after `git add` (its purity gate reads tracked files only).
- Tests stay hermetic: no test spawns rt, herdr, herdr-chat or deck, reads `~/.mattstack`, or reaches the network. `FlockUITests` is the one exception and runs only through `Scripts/e2e.sh`.
- `XCTestCase.setUp`/`tearDown` are not main-actor; a `@MainActor` test class's statics read there must be `nonisolated`.
- Never quit, kill or launch Matt's apps (anything named Flock, including `Flock --bridge` children). Hand builds over with `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev` and tell him to click the restart pill.
- herdr is reference only (`~/Documents/GitHub/herdr`). Never `herdr server stop`, never `pane.scroll`, never `layout.apply` on live panes. Nothing in this plan talks to the default herdr socket except the spike's one `send-keys` on a pane Matt names.
- Commit after every task with a short imperative message ending in `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The worktree is `/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/happy-oyster`, branch `launcher-at-prompt`. Before the first build, copy the gitignored inputs from the main checkout and init the ghostty submodule (Task 0, Step 1).

## Review Focus

Inputs the spec implies but no single feature test owns. Each has a test pinned to the task that owns the code.

1. A pane that renders a frame with the same row count twice (cursor blink) must not re-ask herdr or churn the observation seam. Task 1 (registry ignores an unchanged count) and Task 3 (session reports only a changed count).
2. A render burst whose last frame lands inside the throttle, on an unfocused pane that never renders again, must still be reported. Task 3 (trailing re-check test).
3. A pane that closes while a poll task is sleeping must not have the task touch the registry or herdr afterwards. Task 4 (teardown forgets the pane and cancels the poll).
4. A first report above the cap (a long motd) must not become the prompt height, and a report above eight rows inside a learning window must close the window rather than teach. Task 1.
5. A ⌘ digit pressed while the focused pane is under herdr's rt modal, or in an agent pane, must switch views rather than launch. Task 2 and Task 5 (`focusedPaneShowsLauncher` is false whenever `LaunchTarget` gives no pane).

---

### Task 0: Diagnostic spike (throwaway)

Nothing from this task is committed. Its output is a "Spike findings" note appended to this plan, which Task 1 reads before choosing constants.

**Files:**
- Temporarily modify: `Sources/Flock/FlockApp.swift`, `Sources/Flock/Ghostty/GhosttySession.swift:407-416`, `Sources/FlockCore/ViewModels/SessionViewModel.swift:1297-1316`
- Append to: `docs/superpowers/plans/2026-10-07-pane-launcher-at-prompt.md` (a "Spike findings" section at the end)

- [ ] **Step 1: Prepare the worktree to build**

```bash
cd /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/happy-oyster
MAIN=/Users/matt/Documents/GitHub/flock
cp -cR "$MAIN/Vendor/GhosttyKit.xcframework" Vendor/
cp -cR "$MAIN/Vendor/Sparkle" Vendor/
cp -c "$MAIN/Vendor/libghostty.version" Vendor/
cp -c "$MAIN"/Sources/Flock/Resources/herdr-* Sources/Flock/Resources/
git submodule update --init Vendor/ghostty
xcodegen
```

Expected: `xcodegen` prints the generated project path and no file is reported missing.

- [ ] **Step 2: Add the three temporary log sites**

In `Sources/Flock/FlockApp.swift`, inside `FlockApp`'s `init` (after `self.socketPath = socketPath`), install a local key monitor that logs every ⌘-digit before AppKit dispatches it:

```swift
        // SPIKE: remove before Task 1.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers, "123456789".contains(ch) {
                Logger(subsystem: "dev.mattstack.flock", category: "launcher")
                    .notice("spike key ⌘\(ch, privacy: .public) arrived; menu claims it: \(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)")
            }
            return event
        }
```

`import os` is already present in files using `Logger`; add it at the top of `FlockApp.swift` if the compiler complains.

In `Sources/Flock/Ghostty/GhosttySession.swift`, at the end of `reportScreenActivityIfDue()` after `screenActivityStillWanted = onScreenActivity(nonEmptyRows)`:

```swift
        // SPIKE: remove before Task 1.
        Logger(subsystem: "dev.mattstack.flock", category: "launcher")
            .notice("spike rows \(self.paneID.rawValue, privacy: .public) = \(nonEmptyRows) wanted=\(self.screenActivityStillWanted)")
```

The session's `reportScreenActivityIfDue` currently returns early once `screenActivityStillWanted` is false, so for the spike also change its first line to `guard let onScreenActivity else { return }` so counts keep logging after the launcher hides.

In `Sources/FlockCore/ViewModels/SessionViewModel.swift`, inside `watchNavigation(in:)` right after `let data = try? await client.requestRaw(...)`:

```swift
            // SPIKE: remove before Task 1.
            Logger(subsystem: "dev.mattstack.flock", category: "launcher")
                .notice("spike nav poll \(pane.rawValue, privacy: .public): \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer", privacy: .public)")
```

Add `import os` to the top of `SessionViewModel.swift` for the spike.

- [ ] **Step 3: Build the dev app into the main checkout's dev slot**

```bash
Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev 2>&1 | tail -5
```

Expected: a line naming `build/dev/Flock-dev.app`. Tell Matt: "Spike build is ready, click the New build · Restart pill in Flock Dev."

- [ ] **Step 4: Ask Matt to run the script**

Send Matt this script (rt chat if he is reading there, otherwise in the reply) and wait for him to say he is done:

1. In Flock Dev, make a new tab (⌘T). Wait for the prompt.
2. Press ⌘2 once. Then open the Pane menu, hover Launch so the submenu shows, close it. Press ⌘2 again. If claude started, quit it (Ctrl-C twice).
3. Type `ls` and Enter. Press Ctrl-L. Type `clear` and Enter.
4. Click the rt cd button if it is showing (or type `rt cd` and Enter), pick any folder.
5. Note the pane id shown in the pane's title bar tooltip or the strip, and tell me it. I will send a Ctrl-L to that pane from the herdr CLI; say "ok" when the screen cleared.
6. Rebuild is not needed. Just say "done".

- [ ] **Step 5: Send Ctrl-L to the pane Matt named and read the log**

```bash
~/.local/bin/herdr pane send-keys --pane <PANE_ID> C-l
/usr/bin/log show --predicate 'subsystem == "dev.mattstack.flock" AND category == "launcher"' --last 30m --style compact
```

Expected: the `send-keys` prints a JSON success and Matt confirms the screen cleared. The log shows `spike key` lines (whether the menu claimed ⌘2 before and after opening the submenu), `spike rows` lines (the fresh pane's counts: expect 1 then 2, with 4 if starship's startup warnings print; after `ls` a larger count; after Ctrl-L and `clear` back to 2; after rt cd the count the picker leaves), and `spike nav poll` lines (readable JSON on every poll, or an empty `foreground_processes` at the picker's exit).

- [ ] **Step 6: Record the findings and revert**

Append to the end of this plan file:

```markdown
## Spike findings (2026-10-07)

- ⌘2 before opening the submenu: <claimed by menu: yes/no>; after: <yes/no>; launch logged: <yes/no>.
- Fresh pane row counts: <sequence>. Prompt height: <n>. Startup extras: <n>.
- After `ls`: <n>. After Ctrl-L: <n>. After `clear`: <n>. After rt cd: <n>.
- Nav poll answers: <all readable | an empty foreground list at exit | errors>.
- `send-keys C-l` cleared the screen: <yes/no>.
- Constants to use: unknownHeightCap = <4 unless the prompt is taller>, learningWindow = 2s.
```

Then revert every spike edit (the plan file stays):

```bash
git checkout -- Sources/Flock/FlockApp.swift Sources/Flock/Ghostty/GhosttySession.swift Sources/FlockCore/ViewModels/SessionViewModel.swift
git status --short
git add docs/superpowers/plans/2026-10-07-pane-launcher-at-prompt.md
git commit -m "plan: record launcher spike findings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Expected: `git status --short` shows only the plan file before the commit.

---

### Task 1: `PaneLauncherRegistry` as a state machine over live signals

**Files:**
- Rewrite: `Sources/FlockCore/Input/PaneLauncherRegistry.swift`
- Rewrite: `Tests/FlockCoreTests/PaneLauncherRegistryTests.swift`

**Interfaces:**
- Consumes: `PaneID` (FlockCore).
- Produces, all `@MainActor` on `PaneLauncherRegistry`:
  - `init(pollBackoff: [Duration] = PaneLauncherRegistry.defaultPollBackoff)`
  - `static let learningWindow: TimeInterval = 2`, `static let unknownHeightCap = 4`, `static let tallestPrompt = 8`, `static let navigationStartCeiling: TimeInterval = 3`, `static let defaultPollBackoff: [Duration]`
  - `func recordRows(_ pane: PaneID, rows: Int, at time: Date)`
  - `func recordKeystroke(_ pane: PaneID)`
  - `func recordClearKey(_ pane: PaneID)`
  - `func recordForegroundJob(_ pane: PaneID, idle: Bool?, at time: Date)` (nil = herdr could not say)
  - `func recordNavigationStarted(_ pane: PaneID, at time: Date)`
  - `func isNavigating(_ pane: PaneID) -> Bool`
  - `func forget(_ pane: PaneID)`
  - `func isShowing(_ pane: PaneID) -> Bool`
  - `func nextPollDelay(_ pane: PaneID) -> Duration?` (nil: not a candidate; `.zero`: ask now)
  - `func occupiedRows(_ pane: PaneID) -> Int`

The old `registerFlockCreated`, `recordScreenActivity`, `recordClearRequested`, `wantsScreenActivity`, `forgetNavigation`, `isPristine`, `settleWindow` and `clearWindow` are deleted. `SessionViewModel` and `SessionViewModelTests` call them today, so Step 3 makes the minimal mechanical edits that keep the core target and the test bundle compiling; Task 4 then rewrites that code properly.

- [ ] **Step 1: Replace the test file with the new state machine's tests**

```swift
import XCTest
@testable import FlockCore

/// The launcher's visibility rule, tested standalone: pure bookkeeping over
/// pane ids where every report carries its own timestamp, so nothing here
/// sleeps.
final class PaneLauncherRegistryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let pane = PaneID(rawValue: "w1:p2")

    @MainActor
    private var settled: Date { start.addingTimeInterval(PaneLauncherRegistry.learningWindow) }

    /// A fresh pane: rows 1, then 3, then 4 as starship's startup warnings
    /// print, all inside the learning window, then herdr says idle.
    @MainActor
    func testAFreshPaneLearnsItsPromptAcrossTheWindowAndShowsOnceIdle() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 1, at: start)
        registry.recordRows(pane, rows: 3, at: start.addingTimeInterval(0.3))
        registry.recordRows(pane, rows: 4, at: start.addingTimeInterval(0.6))
        XCTAssertFalse(registry.isShowing(pane), "herdr has not been asked yet")
        XCTAssertEqual(registry.nextPollDelay(pane), .zero, "a bare screen is a candidate: ask now")

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.7))

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "an idle answer ends the asking")
        XCTAssertEqual(registry.occupiedRows(pane), 4)
    }

    @MainActor
    func testOutputAfterTheWindowHidesAndTheNextDropReArms() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 9, at: settled.addingTimeInterval(1))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "output on screen: not a candidate, nothing to ask")

        // `clear` typed: the drop re-arms and re-learns the prompt height.
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(5))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
        registry.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(5.1))
        XCTAssertTrue(registry.isShowing(pane), "a cleared pane at an idle prompt is offered again")
    }

    @MainActor
    func testAKeystrokeHidesAndCtrlLReArmsWithoutAScreenChange() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))

        registry.recordClearKey(pane)
        XCTAssertEqual(registry.nextPollDelay(pane), .zero, "the clear key reopens the question and asks herdr again")
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(1))
        XCTAssertTrue(registry.isShowing(pane))
    }

    /// `clear` then `ls` straight away: the keystrokes close the window before
    /// `ls`'s output lands, so the output is never taken for a prompt.
    @MainActor
    func testTypingInsideTheWindowClosesItSoOutputIsNotLearnedAsPrompt() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 9, at: settled.addingTimeInterval(1))
        // `clear` lands: a drop, a new window.
        registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(2))
        // `ls` typed inside the window, output arrives inside it too.
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 30, at: settled.addingTimeInterval(2.5))

        registry.recordForegroundJob(pane, idle: true, at: settled.addingTimeInterval(2.6))
        XCTAssertFalse(registry.isShowing(pane), "30 rows of ls output must not read as a prompt")
        XCTAssertNil(registry.nextPollDelay(pane))
    }

    /// Inside a window, a report above the tallest prompt anyone draws is
    /// output: it closes the window instead of teaching.
    @MainActor
    func testAReportAboveTheTallestPromptInsideTheWindowIsOutput() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 1, at: start)
        registry.recordRows(pane, rows: PaneLauncherRegistry.tallestPrompt + 10, at: start.addingTimeInterval(0.5))

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.6))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))
    }

    /// A pane first seen mid-life: a small first screen is taken for a bare
    /// prompt; a large one waits for a drop.
    @MainActor
    func testAPaneFirstSeenMidLifeLearnsFromASmallScreenOrWaitsForADrop() {
        let small = PaneLauncherRegistry()
        small.recordRows(pane, rows: PaneLauncherRegistry.unknownHeightCap, at: start)
        XCTAssertEqual(small.nextPollDelay(pane), .zero)
        small.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(small.isShowing(pane))

        let large = PaneLauncherRegistry()
        large.recordRows(pane, rows: PaneLauncherRegistry.unknownHeightCap + 1, at: start)
        XCTAssertNil(large.nextPollDelay(pane), "a screen above the cap is content until a clear says otherwise")
        large.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertFalse(large.isShowing(pane))

        large.recordRows(pane, rows: 2, at: start.addingTimeInterval(10))
        XCTAssertEqual(large.nextPollDelay(pane), .zero, "the drop to a small screen is a clear landing")
        large.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(10.1))
        XCTAssertTrue(large.isShowing(pane))
    }

    @MainActor
    func testBusyHidesAndSchedulesBackoffThatAScreenChangeResets() {
        let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
        let registry = PaneLauncherRegistry(pollBackoff: backoff)
        registry.recordRows(pane, rows: 2, at: start)

        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(0.1))
        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertEqual(registry.nextPollDelay(pane), .milliseconds(500))
        registry.recordForegroundJob(pane, idle: nil, at: start.addingTimeInterval(0.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(1), "an unknown answer is retried like busy, never the end")
        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(1.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(2))
        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(3.6))
        XCTAssertEqual(registry.nextPollDelay(pane), .seconds(2), "the last delay repeats")

        // The prompt repaints (still bare): ask again at once.
        registry.recordRows(pane, rows: 1, at: start.addingTimeInterval(4))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
    }

    /// The cursor blinks and the renderer asks for a frame: the count is the
    /// same, and nothing about the pane may move.
    @MainActor
    func testAnUnchangedRowCountChangesNothing() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.1))
        XCTAssertTrue(registry.isShowing(pane))

        for tick in 1...200 {
            registry.recordRows(pane, rows: 2, at: settled.addingTimeInterval(Double(tick) * 0.6))
        }

        XCTAssertTrue(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane), "no screen change, so no new question for herdr")
    }

    // MARK: - a navigator command (rt cd) run from the launcher

    @MainActor
    func testKeystrokesIntoThePickerDoNotEndTheNavigation() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordNavigationStarted(pane, at: start.addingTimeInterval(1))
        XCTAssertFalse(registry.isShowing(pane), "the launcher steps aside while the picker is up")
        XCTAssertNil(registry.nextPollDelay(pane), "the navigation watch owns the polling meanwhile")

        registry.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(1.3))
        registry.recordKeystroke(pane)
        registry.recordRows(pane, rows: 40, at: start.addingTimeInterval(1.5))

        XCTAssertTrue(registry.isNavigating(pane))
    }

```

The file continues (same class, these close it):

```swift
    @MainActor
    func testAnIdlePaneBeforeThePickerHasStartedIsNotItClosing() {
        let registry = PaneLauncherRegistry()
        registry.recordNavigationStarted(pane, at: start)

        registry.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.3))

        XCTAssertTrue(registry.isNavigating(pane))
    }

    /// A command that fails straight away can finish between two polls. Past
    /// the ceiling, idle means done. An unreadable answer meanwhile is
    /// neither running nor idle.
    @MainActor
    func testTheNavigationEndsOnIdleAfterRunningOrAfterTheCeiling() {
        let seen = PaneLauncherRegistry()
        seen.recordNavigationStarted(pane, at: start)
        seen.recordForegroundJob(pane, idle: false, at: start.addingTimeInterval(0.3))
        seen.recordForegroundJob(pane, idle: nil, at: start.addingTimeInterval(0.6))
        XCTAssertTrue(seen.isNavigating(pane), "herdr could not say: keep polling")
        seen.recordForegroundJob(pane, idle: true, at: start.addingTimeInterval(0.9))
        XCTAssertFalse(seen.isNavigating(pane))

        let unseen = PaneLauncherRegistry()
        unseen.recordNavigationStarted(pane, at: start)
        unseen.recordForegroundJob(
            pane, idle: true, at: start.addingTimeInterval(PaneLauncherRegistry.navigationStartCeiling + 0.1)
        )
        XCTAssertFalse(unseen.isNavigating(pane))
    }

    /// The picker leaves the old prompt and the command line above a new
    /// prompt. Its end clears `typed` and opens a window; the Ctrl-L the view
    /// model then sends drops the screen, and that drop is what shows.
    @MainActor
    func testTheNavigationEndReArmsAndTheClearItTriggersShows() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordNavigationStarted(pane, at: settled)
        registry.recordRows(pane, rows: 40, at: settled.addingTimeInterval(0.5))
        registry.recordForegroundJob(pane, idle: false, at: settled.addingTimeInterval(0.3))
        let closedAt = settled.addingTimeInterval(8)
        registry.recordRows(pane, rows: 4, at: closedAt)
        registry.recordForegroundJob(pane, idle: true, at: closedAt)
        XCTAssertFalse(registry.isNavigating(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 4)

        registry.recordRows(pane, rows: 2, at: closedAt.addingTimeInterval(0.2))
        XCTAssertEqual(registry.nextPollDelay(pane), .zero)
        registry.recordForegroundJob(pane, idle: true, at: closedAt.addingTimeInterval(0.3))
        XCTAssertTrue(registry.isShowing(pane), "back at a bare prompt in the folder the picker chose")
    }

    @MainActor
    func testForgetDropsEverythingAboutThePane() {
        let registry = PaneLauncherRegistry()
        registry.recordRows(pane, rows: 2, at: start)
        registry.recordForegroundJob(pane, idle: true, at: start)
        XCTAssertTrue(registry.isShowing(pane))

        registry.forget(pane)

        XCTAssertFalse(registry.isShowing(pane))
        XCTAssertNil(registry.nextPollDelay(pane))
        XCTAssertEqual(registry.occupiedRows(pane), 0)
    }
}
```

- [ ] **Step 2: Write the registry**

Replace `Sources/FlockCore/Input/PaneLauncherRegistry.swift` with:

```swift
import Foundation

/// Decides, per pane, whether the harness launcher is offered right now.
///
/// The answer is a function of the pane's present state, never its history:
/// the screen holds nothing but a prompt, nothing has been typed since it
/// last emptied, and herdr says the shell holds the foreground. Each signal
/// arrives through its own `record` method with its own timestamp, so this
/// type reads no clock and tests never sleep.
@MainActor
public final class PaneLauncherRegistry {
    /// How long a prompt has to finish painting after the pane first paints,
    /// after the screen drops to bare, or after a navigator ends. A prompt
    /// can land in two frames, and a shell prints warnings on its way up;
    /// erring long only lets a quick command's output in, and a keystroke
    /// closes the window before that output can arrive.
    public static let learningWindow: TimeInterval = 2

    /// The most rows a first screen may hold and still be taken for a bare
    /// prompt when the pane's own prompt height is unknown: a two-line prompt
    /// plus two startup warnings. A two-line prompt, one line of output and
    /// a new prompt is five.
    public static let unknownHeightCap = 4

    /// No prompt is taller than this. A report above it inside a learning
    /// window is output and closes the window instead of teaching.
    public static let tallestPrompt = 8

    /// How long after a navigator command is typed an idle pane still means
    /// the command has yet to start. Past it, idle means it already finished.
    public static let navigationStartCeiling: TimeInterval = 3

    /// Delays between asks of herdr while the shell is busy at a bare screen.
    /// The last one repeats; a screen change starts over.
    public static let defaultPollBackoff: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
    ]

    private enum Foreground {
        case unasked, idle, notIdle
    }

    private struct Navigation {
        let startedAt: Date
        var seenRunning = false
    }

    private struct Pane {
        var promptRows: Int?
        var rows: Int?
        var typed = false
        var learningUntil: Date?
        var foreground: Foreground = .unasked
        var failedAsks = 0
        var navigation: Navigation?

        var isBare: Bool {
            guard let rows, let promptRows else { return false }
            return rows <= promptRows
        }
    }

    private let pollBackoff: [Duration]
    private var panes: [PaneID: Pane] = [:]

    public init(pollBackoff: [Duration] = PaneLauncherRegistry.defaultPollBackoff) {
        precondition(!pollBackoff.isEmpty)
        self.pollBackoff = pollBackoff
    }

    /// The surface's count of non-empty rows on its ACTIVE screen, not its
    /// scrollback: a clear empties the screen and keeps the history, so a
    /// scrollback-wide count could never come back down. A repeat of the
    /// last count is a repaint and changes nothing.
    public func recordRows(_ pane: PaneID, rows: Int, at time: Date) {
        var state = panes[pane] ?? Pane()
        let previous = state.rows
        guard rows != previous else { return }
        state.rows = rows
        state.foreground = .unasked
        state.failedAsks = 0
        defer { panes[pane] = state }
        if state.navigation != nil { return }
        if let until = state.learningUntil, time < until {
            if rows <= Self.tallestPrompt {
                state.promptRows = rows
            } else {
                state.learningUntil = nil
            }
            return
        }
        state.learningUntil = nil
        guard let previous else {
            if rows <= Self.unknownHeightCap {
                state.promptRows = rows
                state.learningUntil = time.addingTimeInterval(Self.learningWindow)
            }
            return
        }
        let bareHeight = state.promptRows ?? Self.unknownHeightCap
        if rows < previous, rows <= bareHeight {
            state.typed = false
            state.promptRows = rows
            state.learningUntil = time.addingTimeInterval(Self.learningWindow)
        }
    }

    /// A real keystroke into the pane. Keys typed while a navigator runs are
    /// the picker's, not the pane's.
    public func recordKeystroke(_ pane: PaneID) {
        var state = panes[pane] ?? Pane()
        guard state.navigation == nil else { return }
        state.typed = true
        state.learningUntil = nil
        panes[pane] = state
    }

    /// The key that asks the shell to clear: an explicit ask for a fresh
    /// screen, so whatever was typed before it no longer counts, and herdr
    /// is asked again.
    public func recordClearKey(_ pane: PaneID) {
        var state = panes[pane] ?? Pane()
        guard state.navigation == nil else { return }
        state.typed = false
        state.foreground = .unasked
        state.failedAsks = 0
        panes[pane] = state
    }

    /// `idle` is whether the shell alone holds the pane's foreground; nil
    /// when herdr could not say. While a navigator runs this drives its end:
    /// idle once the command was seen running, or idle past the start
    /// ceiling. Otherwise it answers the question `nextPollDelay` asked.
    public func recordForegroundJob(_ pane: PaneID, idle: Bool?, at time: Date) {
        var state = panes[pane] ?? Pane()
        defer { panes[pane] = state }
        if var navigation = state.navigation {
            guard let idle else { return }
            if !idle {
                navigation.seenRunning = true
                state.navigation = navigation
                return
            }
            guard navigation.seenRunning
                || time.timeIntervalSince(navigation.startedAt) >= Self.navigationStartCeiling
            else { return }
            state.navigation = nil
            state.typed = false
            state.learningUntil = time.addingTimeInterval(Self.learningWindow)
            state.foreground = .unasked
            state.failedAsks = 0
            return
        }
        if idle == true {
            state.foreground = .idle
            state.failedAsks = 0
        } else {
            state.foreground = .notIdle
            state.failedAsks += 1
        }
    }

    /// A navigator command (a directory picker) was just typed into this
    /// pane. The launcher steps aside until the shell is back at a prompt.
    public func recordNavigationStarted(_ pane: PaneID, at time: Date) {
        var state = panes[pane] ?? Pane()
        state.navigation = Navigation(startedAt: time)
        state.typed = true
        state.learningUntil = nil
        panes[pane] = state
    }

    public func isNavigating(_ pane: PaneID) -> Bool {
        panes[pane]?.navigation != nil
    }

    /// The pane is gone from herdr; nothing about it is worth keeping.
    public func forget(_ pane: PaneID) {
        panes[pane] = nil
    }

    public func isShowing(_ pane: PaneID) -> Bool {
        guard let state = panes[pane], isCandidate(state) else { return false }
        return state.foreground == .idle
    }

    /// nil when the pane is not a candidate (not bare, typed into, under a
    /// navigator, or already answered idle); `.zero` when herdr has not been
    /// asked since the screen last changed; otherwise the wait before asking
    /// again.
    public func nextPollDelay(_ pane: PaneID) -> Duration? {
        guard let state = panes[pane], isCandidate(state) else { return nil }
        switch state.foreground {
        case .idle: return nil
        case .unasked: return .zero
        case .notIdle: return pollBackoff[min(state.failedAsks, pollBackoff.count) - 1]
        }
    }

    /// The rows the pane's screen holds, which the overlay keeps clear of.
    public func occupiedRows(_ pane: PaneID) -> Int {
        panes[pane]?.rows ?? 0
    }

    private func isCandidate(_ state: Pane) -> Bool {
        state.navigation == nil && !state.typed && state.isBare
    }
}
```

- [ ] **Step 3: Keep the view model and its tests compiling**

In `Sources/FlockCore/ViewModels/SessionViewModel.swift`, make only these edits (Task 4 replaces this whole section):

- `isPristineLauncherPane`: body becomes `_ = launcherRegistryVersion; return paneLauncherRegistry.isShowing(pane)`.
- `recordLauncherKeystroke`: replace `paneLauncherRegistry.isPristine(pane)` (both reads) with `paneLauncherRegistry.isShowing(pane)`.
- `recordLauncherScreenActivity(_:nonEmptyRowCount:)`: body becomes `paneLauncherRegistry.recordRows(pane, rows: nonEmptyRowCount, at: now()); launcherRegistryVersion += 1`.
- `recordLauncherClearRequested`: body becomes `paneLauncherRegistry.recordClearKey(pane); launcherRegistryVersion += 1`.
- `wantsLauncherScreenActivity`: body becomes `_ = launcherRegistryVersion; return true`.
- `watchNavigation`: replace `paneLauncherRegistry.forgetNavigation(pane)` with `paneLauncherRegistry.forget(pane)`, and `paneLauncherRegistry.recordForegroundJob(pane, busy: busy, at: now())` with `paneLauncherRegistry.recordForegroundJob(pane, idle: !busy, at: now())`.
- `landIn`: delete the line `paneLauncherRegistry.registerFlockCreated(pane)`.

In `Tests/FlockCoreTests/SessionViewModelTests.swift`, delete these tests outright (Task 4 writes their replacements): `testLaunchNavigatorFocusesThePaneBeforeSubmittingTheCommand`, `testASecondClickWhileTheFirstIsStillSendingTypesNothing`, `testTheLauncherComesBackWhenTheNavigatorCloses`, `testANavigatorHerdrStopsAnsweringForLeavesTheLauncherHidden`, `testGhosttyPaneKeystrokeThroughInputSeamHidesTheLauncher`, `testScreenActivityThroughGhosttySeamHidesTheLauncherAndStopsFurtherReporting`. In `testLaunchHarnessSubmitsWithAnEnterKeyNotANewlineInsideTheText` and `testLaunchHarnessReachesAnUnfocusedPaneViaSendInput`, delete the `XCTAssertTrue(viewModel.isPristineLauncherPane(newPane)...)` lines and keep the `XCTAssertFalse(viewModel.isPristineLauncherPane(newPane)...)` lines as they are (they still compile and still hold).

- [ ] **Step 4: Run the registry tests**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/PaneLauncherRegistryTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*(passed|failed)|error:|BUILD" | tail -30
```

Expected: every `PaneLauncherRegistryTests` case passes; no `error:` lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Input/PaneLauncherRegistry.swift Tests/FlockCoreTests/PaneLauncherRegistryTests.swift Sources/FlockCore/ViewModels/SessionViewModel.swift
Scripts/checks.sh 2>&1 | tail -3
git commit -m "launcher: registry decides from the pane's present state

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `DigitKeyDispatch`

**Files:**
- Create: `Sources/FlockCore/Input/DigitKeyDispatch.swift`
- Create: `Tests/FlockCoreTests/DigitKeyDispatchTests.swift`

**Interfaces:**
- Produces: `public enum DigitKeyDispatch { public enum Outcome: Equatable { case launch(slot: Int), view(index: Int), none }; public static let viewDigits = 3; public static func decide(launcherShowing: Bool, index: Int) -> Outcome }`. `index` is zero-based (⌘1 is 0).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlockCore

/// ⌘1 and on are bound once and decided at press time: into the launcher
/// when the focused pane is offering it, otherwise the views' keys.
final class DigitKeyDispatchTests: XCTestCase {
    func testADigitLaunchesWhileTheLauncherShowsAndSwitchesViewsOtherwise() {
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 0), .launch(slot: 0))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 2), .launch(slot: 2))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 0), .view(index: 0))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 2), .view(index: 2))
    }

    /// Slots past the views' three digits belong to the launcher alone.
    func testDigitsPastTheViewsOnlyEverLaunch() {
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: true, index: 3), .launch(slot: 3))
        XCTAssertEqual(DigitKeyDispatch.decide(launcherShowing: false, index: 3), .none)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/DigitKeyDispatchTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:|Test Case" | head
```

Expected: a compile error naming `DigitKeyDispatch`.

- [ ] **Step 3: Write the implementation**

```swift
/// ⌘1 and on carry two meanings and are bound once: the View menu owns the
/// first three as Workspaces, Overview and Arrange, and a pane offering the
/// launcher borrows them. The choice is made as the key lands, never by
/// moving the key equivalent between menu items.
public enum DigitKeyDispatch {
    public enum Outcome: Equatable {
        case launch(slot: Int)
        case view(index: Int)
        case none
    }

    /// Workspaces, Overview, Arrange.
    public static let viewDigits = 3

    public static func decide(launcherShowing: Bool, index: Int) -> Outcome {
        if launcherShowing { return .launch(slot: index) }
        return index < viewDigits ? .view(index: index) : .none
    }
}
```

- [ ] **Step 4: Regenerate the project, run the test, commit**

```bash
xcodegen
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/DigitKeyDispatchTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*(passed|failed)" 
git add Sources/FlockCore/Input/DigitKeyDispatch.swift Tests/FlockCoreTests/DigitKeyDispatchTests.swift Flock.xcodeproj
Scripts/checks.sh 2>&1 | tail -3
git commit -m "launcher: decide a ⌘ digit's meaning at press time

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Expected: both cases pass. If `Flock.xcodeproj` is gitignored, `git add` of it is a harmless no-op; check with `git check-ignore Flock.xcodeproj`.

---

### Task 3: Continuous row counting on the surface, with a trailing re-check and a cell height

**Files:**
- Modify: `Sources/FlockCore/Ghostty/GhosttyPaneAttaching.swift` (protocol `GhosttyPaneSurface` and `GhosttyPaneFactory.makeSurface`)
- Modify: `Sources/Flock/Ghostty/GhosttySession.swift:377-416` and the `onClearRequested` doc at lines 84-88
- Modify: `Sources/Flock/Ghostty/GhosttyControlSurfaceFactory.swift` (the `makeSurface` signature and the `GhosttySessionSurfaceHandle` conformance)
- Modify: `Sources/Flock/Ghostty/GhosttySurfaceView.swift:640-649` (drop `session.resumeScreenActivityReporting()`)
- Modify: `Tests/FlockCoreTests/SessionViewModelTests.swift` (`FakeGhosttyPaneSurface`, `FakeGhosttyPaneFactory`)
- Create: `Tests/FlockChromeRender/ScreenActivityThrottleTests.swift`

**Interfaces:**
- Produces: `GhosttyPaneSurface` loses `resumeScreenActivityReporting()` and gains `var cellHeight: CGFloat? { get }` (points). `GhosttyPaneFactory.makeSurface(for:onUserInput:onClearRequested:onScreenActivity:)` keeps its parameter names but `onScreenActivity` becomes `@escaping (Int) -> Void`.
- Produces on `GhosttySession`: `var onScreenActivity: ((Int) -> Void)?`, `static let screenActivityInterval: TimeInterval = 0.5`, `var cellHeight: CGFloat?`, and an internal `func noteRenderForScreenActivity(now: Date)` that the RENDER action calls and the throttle test drives directly.

- [ ] **Step 1: Change the protocol and factory seam**

In `GhosttyPaneAttaching.swift`, in `protocol GhosttyPaneSurface`, delete `func resumeScreenActivityReporting()` and its doc comment, and add after `var hasFirstFrame: Bool { get }`:

```swift
    /// One terminal row in points, or nil before libghostty has reported its
    /// cell size. The launcher overlay keeps this many rows clear per row the
    /// screen holds.
    var cellHeight: CGFloat? { get }
```

In `protocol GhosttyPaneFactory`, rewrite the doc comment's `onScreenActivity` paragraph and the signature:

```swift
    /// `onScreenActivity` is the launcher's screen half: called with the
    /// surface's current non-empty active-screen row count whenever that
    /// count changes, for the whole life of the surface. `onClearRequested`
    /// fires on the key that asks the pane to clear its screen, after
    /// `onUserInput` for the same event.
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Void
    ) async -> any GhosttyPaneSurface
```

`import CoreGraphics` at the top of `GhosttyPaneAttaching.swift` for `CGFloat` if Foundation alone does not provide it (it does on macOS; add only if the compiler asks).

- [ ] **Step 2: Rewrite the session's reporting**

In `GhosttySession.swift`, replace the block from `var onScreenActivity: ((Int) -> Bool)?` through the end of `reportScreenActivityIfDue()` (lines 377-416) with:

```swift
    /// The launcher's screen half: called with this pane's current non-empty
    /// active-screen row count each time that count changes (see
    /// `noteRenderForScreenActivity`), for the surface's whole life.
    var onScreenActivity: ((Int) -> Void)?
    /// Counting walks the whole active screen (`ghostty_surface_read_text`
    /// is documented "expensive" by libghostty), so it runs at most this
    /// often. A focused pane renders on every cursor blink.
    static let screenActivityInterval: TimeInterval = 0.5
    private var lastScreenActivityCheck = Date.distantPast
    private var lastReportedRowCount: Int?
    private var trailingScreenActivityCheck: Task<Void, Never>?

    /// `GHOSTTY_ACTION_RENDER` is libghostty asking for a frame: real content
    /// changed, or the cursor blinked. A render inside the interval books one
    /// trailing check at the interval's end, because an unfocused pane never
    /// blinks and so may never render again after a burst.
    func noteRenderForScreenActivity(now: Date = Date()) {
        guard onScreenActivity != nil else { return }
        let elapsed = now.timeIntervalSince(lastScreenActivityCheck)
        guard elapsed >= Self.screenActivityInterval else {
            scheduleTrailingScreenActivityCheck(after: Self.screenActivityInterval - elapsed)
            return
        }
        reportScreenActivity(now: now)
    }

    private func scheduleTrailingScreenActivityCheck(after delay: TimeInterval) {
        guard trailingScreenActivityCheck == nil else { return }
        trailingScreenActivityCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 1))
            guard let self, !Task.isCancelled else { return }
            self.trailingScreenActivityCheck = nil
            self.reportScreenActivity(now: Date())
        }
    }

    /// A test's stand-in for the libghostty read, which needs a live surface.
    var screenRowsOverride: (() -> [String])?

    private func reportScreenActivity(now: Date) {
        trailingScreenActivityCheck?.cancel()
        trailingScreenActivityCheck = nil
        lastScreenActivityCheck = now
        let rows = screenRowsOverride?() ?? readScreenRows()
        let nonEmptyRows = rows.reduce(into: 0) { count, line in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        }
        guard nonEmptyRows != lastReportedRowCount else { return }
        lastReportedRowCount = nonEmptyRows
        onScreenActivity?(nonEmptyRows)
    }

    /// One row in points: libghostty reports the cell in pixels.
    var cellHeight: CGFloat? {
        state.cellSize.map { CGFloat($0.height) / scale }
    }
```

In `handle(_:text:)`, change the RENDER case's second line from `reportScreenActivityIfDue()` to `noteRenderForScreenActivity()`.

Update the `onClearRequested` doc comment (lines 84-88) to:

```swift
    /// Fired by `GhosttySurfaceView.keyDown` for the key that asks a pane to
    /// clear its screen, AFTER `onUserInput` for the same event: clearing is
    /// still typing, so the keystroke lands first and the clear is what
    /// reopens the question the keystroke just closed.
    var onClearRequested: (() -> Void)?
```

`scale` is a private computed property later in the file; `cellHeight` reads it from inside the same type, which is allowed.

- [ ] **Step 3: Update the surface view, the factory and the handle**

In `GhosttySurfaceView.swift` `keyDown`, delete the line `session.resumeScreenActivityReporting()` inside the `ClearKey.isClear` block, leaving `session.onClearRequested?()`.

In `GhosttyControlSurfaceFactory.swift`, change `makeSurface`'s last parameter to `onScreenActivity: @escaping (Int) -> Void`, and in `GhosttySessionSurfaceHandle` replace `func resumeScreenActivityReporting() { ... }` with:

```swift
    var cellHeight: CGFloat? { session.cellHeight }
```

In `SessionViewModelTests.swift`, in `FakeGhosttyPaneSurface` replace the `resumeScreenActivityCallCount` property and `resumeScreenActivityReporting()` with `var cellHeight: CGFloat? = 18`. In `FakeGhosttyPaneFactory`, change `onScreenActivityHandlers: [PaneID: (Int) -> Bool]` to `[PaneID: (Int) -> Void]` and the `makeSurface` parameter to `@escaping (Int) -> Void`. Task 1 already deleted the tests that used the Bool return and the resume counter; if `rg -n "resumeScreenActivity|onScreenActivity\(.*\)\)" Tests` still finds a use, remove it. In `SessionViewModel.attachPane`, the closure handed to `makeSurface` currently returns a Bool; make it `onScreenActivity: { [weak self] rows in self?.recordLauncherScreenActivity(pane, nonEmptyRowCount: rows) }` for now (Task 4 renames it).

- [ ] **Step 4: Write the throttle test (FlockChromeRender compiles `Sources/Flock`)**

Create `Tests/FlockChromeRender/ScreenActivityThrottleTests.swift`:

```swift
import FlockCore
import XCTest
@testable import Flock

/// The row count is a full active-screen scan, so renders are throttled; the
/// last render of a burst still has to be seen, because an unfocused pane
/// never renders again on its own.
@MainActor
final class ScreenActivityThrottleTests: XCTestCase {
    private func makeSession() -> GhosttySession {
        let host = GhosttyHost()
        return host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: .init(commandArgv: ["/usr/bin/true"], themeColors: Theme.builtins[0].ghosttyColors, fontSizePoints: 13, optionAsAlt: .off)
        )
    }

    /// Three renders in 200ms: the first reports at once, the screen grows
    /// under the next two, and the growth is reported exactly once, by the
    /// trailing check, after the interval.
    func testARenderInsideTheIntervalIsReportedOnceAtTheIntervalsEnd() async {
        let session = makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }
        let start = Date()

        session.noteRenderForScreenActivity(now: start)
        screen = ["prompt", "output"]
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.1))
        screen = ["prompt", "output", "more"]
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.2))
        XCTAssertEqual(reports, [1], "renders inside the interval wait for the trailing check")

        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(reports, [1, 3], "the trailing check reports the screen as it is at the interval's end, once")
    }

    /// The cursor blinks: the same screen again is not a report.
    func testAnUnchangedScreenIsNotReportedAgain() async {
        let session = makeSession()
        var reports: [Int] = []
        session.screenRowsOverride = { ["prompt", "", "   "] }
        session.onScreenActivity = { reports.append($0) }
        let start = Date()

        session.noteRenderForScreenActivity(now: start)
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.6))
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(1.2))

        XCTAssertEqual(reports, [1], "blank and whitespace rows do not count, and a repeat says nothing")
    }
}
```

If `GhosttyHost()` cannot be constructed without a real libghostty app in the test process, replace `makeSession()` with whatever `ChromeRenderTests` or `RtModalChromeRenderTests` already uses to obtain a `GhosttySession` (search those files for `makeSession(` and `GhosttyHost`), and if no test anywhere builds one, give `GhosttySession` a second, test-only initializer path is NOT the answer: instead move the throttle into a small `ScreenActivityThrottle` value type in `Sources/Flock/Ghostty/` (inputs: `note(now:)` returning `.report`, `.wait(TimeInterval)` or `.nothing`; state: last check time) that the session drives, and test that type directly with the same two cases rephrased. Either way the two behaviors above must be pinned by a test before the commit. The `Launch` initializer's exact argument labels are in `GhosttySession.swift`; match them.

- [ ] **Step 5: Build both test targets' compile step and run the two suites**

```bash
xcodebuild build-for-testing -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:|BUILD" | head
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ScreenActivityThrottleTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*(passed|failed)|error:" | head
```

Expected: `BUILD SUCCEEDED`; the throttle case passes. `FlockCoreTests` may not compile until Task 4 finishes the view model; that is expected.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlockCore/Ghostty/GhosttyPaneAttaching.swift Sources/Flock/Ghostty/GhosttySession.swift Sources/Flock/Ghostty/GhosttyControlSurfaceFactory.swift Sources/Flock/Ghostty/GhosttySurfaceView.swift Tests/FlockCoreTests/SessionViewModelTests.swift Tests/FlockChromeRender/ScreenActivityThrottleTests.swift
xcodegen && Scripts/checks.sh 2>&1 | tail -3
git commit -m "ghostty: count rows for the surface's whole life, with a trailing check

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `SessionViewModel` feeds the registry and owns the polls

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (lines 128-131 registry property, 169-178 `navigationWatches`, the `init` signature at 180-230, `attachPane`'s `makeSurface` call at 1115-1127, `performTeardown` at 1189-1194, the whole `// MARK: - new-pane harness launcher` section 1183-1316, and `landIn` at 1349-1353)
- Modify: `Tests/FlockCoreTests/SessionViewModelTests.swift` (replace the launcher tests at 960-1110 and 1674-1730)

**Interfaces:**
- Consumes: `PaneLauncherRegistry` (Task 1), `GhosttyPaneFactory.makeSurface` with `(Int) -> Void` (Task 3), `LaunchTarget.pane(canvasPane:agent:)`, `PaneForegroundJob.isBusy(processInfoResponse:)`.
- Produces on `SessionViewModel`:
  - `init(..., launcherPollBackoff: [Duration] = PaneLauncherRegistry.defaultPollBackoff, ...)`
  - `public private(set) var launcherRegistryVersion: Int`
  - `public func isLauncherShowing(_ pane: PaneID) -> Bool`
  - `public func launcherOccupiedRows(_ pane: PaneID) -> Int`
  - `public var focusedPaneShowsLauncher: Bool`
  - `public func recordLauncherKeystroke(_ pane: PaneID)`
  - `public func recordLauncherClearKey(_ pane: PaneID)`
  - `public func recordLauncherRows(_ pane: PaneID, rows: Int)`
  - `public func isAtPrompt(_ pane: PaneID) async -> Bool` (unchanged)
  - `public func launchHarness(_ binary: String, in pane: PaneID) async` (unchanged signature)
  - `public func launchNavigator(_ command: String, in pane: PaneID) async` (unchanged signature; now ends with `pane.send_keys` `C-l`)
  - `var promptWatches: [PaneID: Task<Void, Never>]` and `var navigationWatches` (internal, for tests)
- Deleted: `isPristineLauncherPane`, `recordLauncherScreenActivity`, `recordLauncherClearRequested`, `wantsLauncherScreenActivity`.

- [ ] **Step 1: Write the failing tests**

Task 1 already deleted the six obsolete tests. In `SessionViewModelTests.swift`, in `testLaunchHarnessSubmitsWithAnEnterKeyNotANewlineInsideTheText` and `testLaunchHarnessReachesAnUnfocusedPaneViaSendInput`, replace each remaining `XCTAssertFalse(viewModel.isPristineLauncherPane(newPane) ...)` with `XCTAssertFalse(viewModel.isLauncherShowing(newPane), ...)` keeping the message. Then add, where the deleted navigator tests were:

```swift
    /// No focused pane (no model yet): the digits are the views' keys.
    @MainActor
    func testFocusedPaneShowsLauncherIsFalseWithoutAFocusedShellPane() async throws {
        let client = StubForegroundClient([.idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.milliseconds(1)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        try XCTUnwrap(factory.onScreenActivityHandlers[pane])(2)
        await XCTUnwrap(viewModel.promptWatches[pane]).value
        XCTAssertTrue(viewModel.isLauncherShowing(pane))

        XCTAssertFalse(viewModel.focusedPaneShowsLauncher, "nothing is focused on the canvas, so ⌘1 is Workspaces")
    }

    // MARK: - the launcher follows the pane's present state

    /// The ghostty seam reports a bare screen; the view model asks herdr
    /// once and shows on idle. The same count again asks nothing.
    @MainActor
    func testABareScreenAsksHerdrOnceAndShowsOnIdle() async throws {
        let client = StubForegroundClient([.idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.milliseconds(1)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[pane])
        let versionBefore = viewModel.launcherRegistryVersion

        onScreenActivity(2)
        let watch = try XCTUnwrap(viewModel.promptWatches[pane])
        await watch.value

        XCTAssertTrue(viewModel.isLauncherShowing(pane))
        XCTAssertGreaterThan(viewModel.launcherRegistryVersion, versionBefore, "the seam moved so SwiftUI re-reads")
        onScreenActivity(2)
        XCTAssertNil(viewModel.promptWatches[pane], "a repeated count is a repaint: nothing to ask")
        let polls = await client.calls.filter { $0.method == "pane.process_info" }
        XCTAssertEqual(polls.count, 1)
    }

    /// Busy, then a failed request, then idle: every answer is retried, and
    /// the pane shows once the shell is back.
    @MainActor
    func testBusyAndFailedAnswersAreRetriedUntilIdle() async throws {
        let client = StubForegroundClient([.busy, .failure, .idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.milliseconds(1)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[pane])

        onScreenActivity(2)
        for _ in 0..<3 {
            guard let watch = viewModel.promptWatches[pane] else { break }
            await watch.value
        }

        XCTAssertTrue(viewModel.isLauncherShowing(pane))
        let polls = await client.calls.filter { $0.method == "pane.process_info" }
        XCTAssertEqual(polls.count, 3)
        XCTAssertNil(viewModel.promptWatches[pane])
    }

    @MainActor
    func testAKeystrokeHidesAndCancelsThePendingPoll() async throws {
        let client = StubForegroundClient([.busy])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.seconds(60)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[pane])
        onScreenActivity(2)
        let first = try XCTUnwrap(viewModel.promptWatches[pane])
        await first.value
        let waiting = try XCTUnwrap(viewModel.promptWatches[pane], "busy: a retry is booked")

        try XCTUnwrap(factory.onUserInputHandlers[pane])()

        XCTAssertTrue(waiting.isCancelled)
        XCTAssertNil(viewModel.promptWatches[pane])
        XCTAssertFalse(viewModel.isLauncherShowing(pane))
    }

    /// A pane herdr closes mid-poll: the registry forgets it and the sleeping
    /// task never asks herdr about it again.
    @MainActor
    func testTearingDownAPaneForgetsItAndCancelsItsPoll() async throws {
        let client = StubForegroundClient([.busy])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.seconds(60)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        try XCTUnwrap(factory.onScreenActivityHandlers[pane])(2)
        await XCTUnwrap(viewModel.promptWatches[pane]).value
        let waiting = try XCTUnwrap(viewModel.promptWatches[pane])

        await viewModel.detachPane(pane)
        viewModel.update(model: nil, connection: .connected)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertTrue(waiting.isCancelled)
        XCTAssertEqual(viewModel.launcherOccupiedRows(pane), 0, "forgotten")
    }

    // MARK: - a navigator command (rt cd) launched from the launcher

    @MainActor
    func testLaunchNavigatorFocusesThePaneBeforeSubmittingTheCommand() async throws {
        let client = StubForegroundClient([.busy])
        let viewModel = SessionViewModel(client: client, navigationPollInterval: .milliseconds(1))
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p1"))

        await viewModel.launchNavigator("rt cd", in: newPane)

        let calls = await client.calls
        let focusIndex = try XCTUnwrap(calls.lastIndex { $0.method == "pane.focus" })
        let sendIndex = try XCTUnwrap(calls.lastIndex { $0.method == "pane.send_input" })
        XCTAssertEqual(stringParam(calls[focusIndex].params, "pane_id"), "w1:p2")
        XCTAssertLessThan(focusIndex, sendIndex, "the picker takes keys the moment it opens")
        XCTAssertEqual(stringParam(calls[sendIndex].params, "text"), "rt cd")
        XCTAssertEqual(stringArrayParam(calls[sendIndex].params, "keys"), ["Enter"])
        XCTAssertFalse(viewModel.isLauncherShowing(newPane), "the launcher steps aside for the picker")
        viewModel.navigationWatches[newPane]?.cancel()
    }

    @MainActor
    func testASecondClickWhileTheFirstIsStillSendingTypesNothing() async throws {
        let client = StubForegroundClient([.busy])
        let viewModel = SessionViewModel(client: client, navigationPollInterval: .milliseconds(1))
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")

        async let first: Void = viewModel.launchNavigator("rt cd", in: newPane)
        async let second: Void = viewModel.launchNavigator("rt cd", in: newPane)
        _ = await (first, second)

        let sends = await client.calls.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(sends.count, 1)
        viewModel.navigationWatches[newPane]?.cancel()
    }

    /// Busy, an unreadable answer, then idle: the watch survives the bad
    /// answer, and the picker's end is followed by a Ctrl-L so the pane is
    /// bare again for the generic rule to show on.
    @MainActor
    func testTheNavigatorSurvivesABadAnswerAndClearsThePaneWhenThePickerCloses() async throws {
        let client = StubForegroundClient([.busy, .failure, .idle, .idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(
            client: client, ghosttyFactory: factory, navigationPollInterval: .milliseconds(1),
            launcherPollBackoff: [.milliseconds(1)]
        )
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(newPane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[newPane])
        onScreenActivity(2)
        await XCTUnwrap(viewModel.promptWatches[newPane]).value

        await viewModel.launchNavigator("rt cd", in: newPane)
        let watch = try XCTUnwrap(viewModel.navigationWatches[newPane])
        await watch.value

        let calls = await client.calls
        let keys = try XCTUnwrap(calls.last { $0.method == "pane.send_keys" })
        XCTAssertEqual(stringParam(keys.params, "pane_id"), "w1:p2")
        XCTAssertEqual(stringArrayParam(keys.params, "keys"), ["C-l"])
        XCTAssertNil(viewModel.navigationWatches[newPane])
        XCTAssertFalse(viewModel.isLauncherShowing(newPane), "the screen has not dropped yet")

        // The Ctrl-L lands: the drop is a candidate, herdr says idle, shown.
        onScreenActivity(4)
        onScreenActivity(2)
        await XCTUnwrap(viewModel.promptWatches[newPane]).value
        XCTAssertTrue(viewModel.isLauncherShowing(newPane))
    }

    /// The ghostty input seam: a keystroke reported through `onUserInput`
    /// hides the launcher.
    @MainActor
    func testGhosttyPaneKeystrokeThroughInputSeamHidesTheLauncher() async throws {
        let client = StubForegroundClient([.idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, launcherPollBackoff: [.milliseconds(1)])
        let pane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(pane)
        try XCTUnwrap(factory.onScreenActivityHandlers[pane])(2)
        await XCTUnwrap(viewModel.promptWatches[pane]).value
        XCTAssertTrue(viewModel.isLauncherShowing(pane))

        try XCTUnwrap(factory.onUserInputHandlers[pane])()

        XCTAssertFalse(viewModel.isLauncherShowing(pane))
    }
```

`StubForegroundClient` answers `pane.send_keys` and `pane.focus` with `{}` through its `default` case already; `.failure` throws. If `viewModel.update(model:connection:)`'s parameter types differ (search the file for `func update(model:`), use the same arguments the existing teardown tests pass; the intent is a model without `w1:p2` after it was known.

- [ ] **Step 2: Run the new tests to see them fail**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/SessionViewModelTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:" | head
```

Expected: compile errors for `launcherPollBackoff`, `promptWatches`, `isLauncherShowing`, `launcherOccupiedRows`.

- [ ] **Step 3: Rewrite the view model's launcher section**

In `SessionViewModel.swift`:

Line 130: `private let paneLauncherRegistry = PaneLauncherRegistry()` becomes `private let paneLauncherRegistry: PaneLauncherRegistry`.

After `navigationWatches` (line 178) add:

```swift
    /// One per pane whose screen is bare and whose shell herdr has not yet
    /// called idle, until it does or the pane stops being a candidate.
    @ObservationIgnored var promptWatches: [PaneID: Task<Void, Never>] = [:]
```

Add `launcherPollBackoff: [Duration] = PaneLauncherRegistry.defaultPollBackoff,` to `init` after `navigationPollInterval:`, and `self.paneLauncherRegistry = PaneLauncherRegistry(pollBackoff: launcherPollBackoff)` in the body before any use.

In `attachPane` (lines 1115-1127), replace the three-closure `makeSurface` call with:

```swift
        let surface = await factory.makeSurface(
            for: pane,
            onUserInput: { [weak self] in self?.recordLauncherKeystroke(pane) },
            onClearRequested: { [weak self] in self?.recordLauncherClearKey(pane) },
            onScreenActivity: { [weak self] rows in self?.recordLauncherRows(pane, rows: rows) }
        )
```

and delete the comment block above it about the "launcher-pristine contract".

In `performTeardown(pane:)` add, before `await surface.detach()`:

```swift
        promptWatches[pane]?.cancel()
        promptWatches[pane] = nil
        navigationWatches[pane]?.cancel()
        navigationWatches[pane] = nil
        paneLauncherRegistry.forget(pane)
        launcherRegistryVersion += 1
```

Replace the whole `// MARK: - new-pane harness launcher` section (from that MARK through the end of `watchNavigation`) with:

```swift
    // MARK: - harness launcher

    /// `PaneLauncherRegistry` is a plain (non-`@Observable`) class, so a
    /// mutation to it alone would never invalidate a SwiftUI view reading
    /// it. This counter is the observation seam: every change below that
    /// moves a pane's answer bumps it, and the readers below touch it
    /// (result discarded) purely to register that dependency.
    public private(set) var launcherRegistryVersion = 0

    public func isLauncherShowing(_ pane: PaneID) -> Bool {
        _ = launcherRegistryVersion
        return paneLauncherRegistry.isShowing(pane)
    }

    /// The rows the pane's screen holds, which the overlay keeps clear of.
    public func launcherOccupiedRows(_ pane: PaneID) -> Int {
        _ = launcherRegistryVersion
        return paneLauncherRegistry.occupiedRows(pane)
    }

    /// Whether ⌘1 and on launch rather than switch views: the canvas's
    /// focused pane, with no detected agent, is showing the launcher.
    public var focusedPaneShowsLauncher: Bool {
        let pane = canvasFocusedPaneID
        guard let target = LaunchTarget.pane(canvasPane: pane, agent: pane.flatMap { model?.panes[$0]?.agent }) else {
            return false
        }
        return isLauncherShowing(target)
    }

    /// On the key path: `GhosttySurfaceView.keyDown` calls this for every
    /// real keystroke.
    public func recordLauncherKeystroke(_ pane: PaneID) {
        launcherChange(pane) { $0.recordKeystroke(pane) }
    }

    /// The key that asks the shell to clear, after the keystroke above.
    public func recordLauncherClearKey(_ pane: PaneID) {
        launcherChange(pane) { $0.recordClearKey(pane) }
    }

    /// The surface's non-empty active-screen row count, each time it changes.
    public func recordLauncherRows(_ pane: PaneID, rows: Int) {
        launcherChange(pane) { $0.recordRows(pane, rows: rows, at: now()) }
    }

    /// Applies one registry mutation, bumps the observation seam when the
    /// pane's answer or occupied rows moved, and re-arms or cancels the
    /// pane's herdr poll to match the registry's new question.
    private func launcherChange(_ pane: PaneID, _ mutate: (PaneLauncherRegistry) -> Void) {
        let showingBefore = paneLauncherRegistry.isShowing(pane)
        let rowsBefore = paneLauncherRegistry.occupiedRows(pane)
        mutate(paneLauncherRegistry)
        if showingBefore != paneLauncherRegistry.isShowing(pane) || rowsBefore != paneLauncherRegistry.occupiedRows(pane) {
            launcherRegistryVersion += 1
        }
        schedulePromptPoll(pane)
    }

    private func schedulePromptPoll(_ pane: PaneID) {
        promptWatches[pane]?.cancel()
        promptWatches[pane] = nil
        guard let delay = paneLauncherRegistry.nextPollDelay(pane) else { return }
        promptWatches[pane] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let data = try? await self.client.requestRaw("pane.process_info", ["pane_id": .string(pane.rawValue)])
            guard !Task.isCancelled else { return }
            let idle = data.flatMap { PaneForegroundJob.isBusy(processInfoResponse: $0) }.map { !$0 }
            self.launcherChange(pane) { $0.recordForegroundJob(pane, idle: idle, at: self.now()) }
        }
    }

    /// Sends `binary` to `pane` and submits it in one `send_input` call, then
    /// hides the launcher for that pane at once, as a keystroke would, so a
    /// second click before the program paints types nothing.
    ///
    /// The Enter rides `keys`, never a newline inside `text`: herdr wraps a
    /// non-empty `text` in a bracketed-paste sequence whenever the pane's
    /// program enabled it (a shell at a prompt does), and a newline inside
    /// that bracket reaches the line editor as a literal newline rather than
    /// accept-line. `keys` is encoded outside the bracket.
    public func launchHarness(_ binary: String, in pane: PaneID) async {
        _ = try? await client.requestRaw(
            "pane.send_input",
            [
                "pane_id": .string(pane.rawValue),
                "text": .string(binary),
                "keys": .array([.string("Enter")]),
            ]
        )
        recordLauncherKeystroke(pane)
    }

    /// Asked of herdr at the moment of launching, never cached: a command
    /// typed into anything but a shell at its prompt reaches that program as
    /// input. `false` when herdr cannot say.
    public func isAtPrompt(_ pane: PaneID) async -> Bool {
        guard let data = try? await client.requestRaw("pane.process_info", ["pane_id": .string(pane.rawValue)]) else {
            return false
        }
        return PaneForegroundJob.isBusy(processInfoResponse: data) == false
    }

    /// Runs a navigator command (a directory picker such as `rt cd`) in
    /// `pane`, focused first because the picker takes keys the moment it
    /// opens. The launcher steps aside while it runs; when the shell is back
    /// at its prompt the pane is sent Ctrl-L, so the screen the picker left
    /// drops to a bare prompt and the ordinary rule offers the launcher again.
    public func launchNavigator(_ command: String, in pane: PaneID) async {
        guard !paneLauncherRegistry.isNavigating(pane) else { return }
        // Before the round trips below: until this lands the button is still
        // on screen, and a second click would type the command twice.
        launcherChange(pane) { $0.recordNavigationStarted(pane, at: now()) }
        await jumpToHerdr(pane: pane)
        _ = try? await client.requestRaw(
            "pane.send_input",
            [
                "pane_id": .string(pane.rawValue),
                "text": .string(command),
                "keys": .array([.string("Enter")]),
            ]
        )
        navigationWatches[pane]?.cancel()
        navigationWatches[pane] = Task { [weak self] in await self?.watchNavigation(in: pane) }
    }

    /// Polls `pane.process_info` until the registry says the navigation is
    /// over. An answer herdr cannot give (an error, an empty foreground list
    /// as the picker exits) is retried on the next tick; only the pane going
    /// away (`performTeardown` cancels this task) ends the watch early.
    private func watchNavigation(in pane: PaneID) async {
        while !Task.isCancelled, paneLauncherRegistry.isNavigating(pane) {
            try? await Task.sleep(for: navigationPollInterval)
            guard !Task.isCancelled else { return }
            let data = try? await client.requestRaw("pane.process_info", ["pane_id": .string(pane.rawValue)])
            guard !Task.isCancelled else { return }
            let idle = data.flatMap { PaneForegroundJob.isBusy(processInfoResponse: $0) }.map { !$0 }
            paneLauncherRegistry.recordForegroundJob(pane, idle: idle, at: now())
        }
        guard !Task.isCancelled else { return }
        _ = try? await client.requestRaw(
            "pane.send_keys",
            ["pane_id": .string(pane.rawValue), "keys": .array([.string("C-l")])]
        )
        navigationWatches[pane] = nil
        launcherRegistryVersion += 1
        schedulePromptPoll(pane)
    }
```

In `landIn(pane:)` delete the two lines `paneLauncherRegistry.registerFlockCreated(pane)` and `launcherRegistryVersion += 1`, and trim its doc comment to:

```swift
    /// flock's own half of the `focus: true` every create request carries:
    /// the new pane is the input sink from the moment herdr answers, rather
    /// than from whenever its focus echo arrives, and if that echo never
    /// arrives, this is the only thing that ever put the user in what they
    /// just made.
    private func landIn(pane: PaneID) {
        optimisticFocusedPaneID = pane
    }
```

- [ ] **Step 4: Run the FlockCore suite for the two launcher files**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/SessionViewModelTests -only-testing:FlockCoreTests/PaneLauncherRegistryTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*(failed)|error:|Executed" | head -20
```

Expected: `Executed N tests, with 0 failures`. If a test awaiting `promptWatches[pane]` finds it nil because the poll finished synchronously before the await, the registry already answered: read `isLauncherShowing` directly instead of awaiting.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/ViewModels/SessionViewModel.swift Tests/FlockCoreTests/SessionViewModelTests.swift
Scripts/checks.sh 2>&1 | tail -3
git commit -m "launcher: the view model polls herdr for candidate panes and clears after rt cd

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Menu, palette, overlay wiring and the rename

**Files:**
- Modify: `Sources/Flock/Views/PaneLauncherOverlay.swift:95-121` (`LauncherSlots.target/launchInFocusedPane/launch`)
- Modify: `Sources/Flock/FlockApp.swift:266-271` (delete `launcherOffered`), `:408-421` (Launch submenu), `:546-559` (View digit items)
- Modify: `Sources/Flock/Palette/PaletteRunner.swift:63`
- Modify: `Sources/Flock/Views/PaneCellView.swift:817`, `:844-852`, `:868`
- Modify: `Sources/Flock/Views/PaneTerminalView.swift` (every `isPristineLauncherPane`), `Sources/Flock/Ghostty/GhosttySurfaceView.swift:89-92`, `:172`
- Modify: `Sources/FlockCore/Marks/PaneLoaderPolicy.swift:69-83`, `Tests/FlockCoreTests/PaneLoaderPolicyTests.swift:86-110`
- Modify: any file `rg -l isPristineLauncherPane Sources Tests` still lists

**Interfaces:**
- Consumes: `DigitKeyDispatch` (Task 2), `SessionViewModel.focusedPaneShowsLauncher`, `isLauncherShowing`, `launchHarness`, `launchNavigator`, `isAtPrompt` (Task 4).
- Produces: `LauncherSlots.LaunchPath` (`enum LaunchPath: String { case click, key, palette }`, nested in `LauncherSlots`) and `LauncherSlots.launch(_ entry: HarnessEntry, in pane: PaneID, via path: LaunchPath, on viewModel: SessionViewModel) async`, `LauncherSlots.launchInFocusedPane(_ entry: HarnessEntry, via path: LaunchPath, on viewModel: SessionViewModel) async`. `PaneLoaderPolicy.showsLauncherOverlay(isLauncherShowing:hasFirstFrame:badgeVisible:)`.

- [ ] **Step 1: Rename the policy parameter, test first**

In `PaneLoaderPolicyTests.swift`, replace every `isPristineLauncherPane:` label with `isLauncherShowing:` (lines 86, 95, 101, 107, 110). Run:

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/PaneLoaderPolicyTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:" | head -3
```

Expected: an "incorrect argument label" error. Then in `PaneLoaderPolicy.swift` rename the parameter in `showsLauncherOverlay` and change its doc's first paragraph to:

```swift
    /// A fresh pane is both things at once: it has no first frame yet, and
    /// its registry answer may already say the launcher shows.
```

(keep the rest of the comment). Re-run; expected pass.

- [ ] **Step 2: One launch function with a path and a log line**

In `PaneLauncherOverlay.swift`, replace `launchInFocusedPane` and `launch` (lines 100-121) with:

```swift
    /// A click on the overlay's button, a ⌘ digit, or a palette row: the
    /// three ways a launch starts, named in the log so a dead key can be told
    /// from a press herdr refused.
    enum LaunchPath: String {
        case click, key, palette
    }

    /// ⌘1 and on, and the palette's rows: the pane is read as the key lands,
    /// never captured when the menu last rendered.
    @MainActor
    static func launchInFocusedPane(_ entry: HarnessEntry, via path: LaunchPath, on viewModel: SessionViewModel) async {
        guard let pane = target(on: viewModel) else { return }
        await launch(entry, in: pane, via: path, on: viewModel)
    }

    /// Every launch asks herdr whether the shell holds the pane's foreground
    /// as it fires: the overlay was shown on an answer that may be stale by
    /// the time of the click, and a command typed into anything but a shell
    /// at its prompt reaches that program as input.
    @MainActor
    static func launch(_ entry: HarnessEntry, in pane: PaneID, via path: LaunchPath, on viewModel: SessionViewModel) async {
        let atPrompt = await viewModel.isAtPrompt(pane)
        log.notice(
            "launch \(entry.id, privacy: .public) via \(path.rawValue, privacy: .public) in \(pane.rawValue, privacy: .public): at prompt \(atPrompt)"
        )
        guard atPrompt else { return NSSound.beep() }
        if entry.id == NavigatorRoster.rtCd.id {
            await viewModel.launchNavigator(NavigatorRoster.command, in: pane)
        } else {
            await viewModel.launchHarness(entry.binary, in: pane)
        }
    }
```

Keep `target(on:)` and the `log` as they are.

- [ ] **Step 3: The menus**

In `FlockApp.swift`, delete the `launcherOffered` property (lines 266-271 including its doc comment).

Replace the Launch submenu (lines 408-421) with:

```swift
                // Disabled under an agent, where ⌘1 and on reach the pane's
                // program as they did before.
                let canLaunch = LauncherSlots.target(on: viewModel) != nil
                Menu("Launch") {
                    ForEach(Array(LauncherSlots.current().enumerated()), id: \.element.id) { index, entry in
                        Button(LauncherSlots.title(for: entry)) {
                            Task { await LauncherSlots.launchInFocusedPane(entry, via: .key, on: viewModel) }
                        }
                        // The first three digits are the View menu's, which
                        // dispatch here while the launcher shows; slots past
                        // them carry their own key.
                        .keyboardShortcut(
                            index < DigitKeyDispatch.viewDigits
                                ? nil : KeyboardShortcut(LauncherSlots.key(at: index), modifiers: .command)
                        )
                        .disabled(!canLaunch)
                        .accessibilityIdentifier("flock.pane.launch.\(entry.id)")
                    }
                }
```

Replace the View digit items (lines 546-559) with:

```swift
                ForEach(Array(ViewTab.allCases.enumerated()), id: \.element) { index, tab in
                    let command = ViewCommand.show(tab)
                    Button {
                        // Decided as the key lands, never by moving the key
                        // equivalent: a pane offering the launcher borrows
                        // the digit, and SwiftUI's menu refresh is not in
                        // the loop.
                        switch DigitKeyDispatch.decide(launcherShowing: viewModel.focusedPaneShowsLauncher, index: index) {
                        case .launch(let slot):
                            let slots = LauncherSlots.current()
                            guard slot < slots.count else { return viewTabs.choose(tab) }
                            Task { await LauncherSlots.launchInFocusedPane(slots[slot], via: .key, on: viewModel) }
                        case .view, .none:
                            viewTabs.choose(tab)
                        }
                    } label: {
                        if viewTabs.selected == tab {
                            Label(command.title, systemImage: "checkmark")
                        } else {
                            Text(command.title)
                        }
                    }
                    .keyboardShortcut(command.shortcut)
                    .accessibilityIdentifier(command.accessibilityIdentifier)
                }
```

`ViewTab.allCases` order is workspaces, overview, arrange, which matches ⌘1, ⌘2, ⌘3 (`ViewCommand.key` reads `viewTab.digit`; confirm `ViewTab.digit` gives "1", "2", "3" in that order with `rg -n "digit" Sources/FlockCore/Grid/ViewTab.swift`).

In `PaletteRunner.swift` line 63: `Task { await LauncherSlots.launchInFocusedPane(entry, via: .palette, on: viewModel) }`.

- [ ] **Step 4: The cell, the terminal view, the surface view**

In `PaneCellView.swift`:
- line 817: `isLauncherShowing: viewModel.isLauncherShowing(pane.paneID),`
- lines 844-852: 

```swift
                if PaneLoaderPolicy.showsLauncherOverlay(
                    isLauncherShowing: viewModel.isLauncherShowing(pane.paneID),
                    hasFirstFrame: ghosttySurface.hasFirstFrame, badgeVisible: showsAttachLoader
                ) {
                    PaneLauncherOverlay(
                        theme: theme, entries: HarnessRoster.detected(), navigator: NavigatorRoster.detected(),
                        onLaunch: { entry in Task { await LauncherSlots.launch(entry, in: pane.paneID, via: .click, on: viewModel) } }
                    )
                    .transition(.opacity)
                }
```

- line 868: `guard !isFocused, viewModel.isLauncherShowing(pane.paneID) else { return }`

Rename `isPristineLauncherPane` to `isLauncherShowing` everywhere else it appears:

```bash
rg -l "isPristineLauncherPane" Sources Tests | xargs sed -i '' 's/isPristineLauncherPane/isLauncherShowing/g'
rg -n "isLauncherShowing" Sources/Flock/Ghostty/GhosttySurfaceView.swift Sources/Flock/Views/PaneTerminalView.swift | head
```

Then fix the two doc comments the sed left stale: in `GhosttySurfaceView.swift` (around line 89) and `PaneTerminalView.swift` (around line 31), change "`SessionViewModel.isPristineLauncherPane`" references (now `isLauncherShowing`) so the sentence reads "`SessionViewModel.isLauncherShowing`: while true this pane's surface claims no mouse point at all, so `PaneLauncherOverlay`'s button row (drawn above it in SwiftUI) receives clicks and hover." Also rename `GhosttySurfaceView.pristinePaneTakes` to `launcherPaneTakes` and its uses in `RightClickRoutingTests.swift`.

- [ ] **Step 5: Build everything and run the render and core suites**

```bash
xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:|BUILD" | head
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*failed|error:|Executed" | tail -5
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*failed|error:|Executed" | tail -5
```

Expected: `BUILD SUCCEEDED` and `0 failures` in both suites.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
Scripts/checks.sh 2>&1 | tail -3
git commit -m "launcher: ⌘ digits bound once and decided at press time; one launch path

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The overlay keeps clear of the rows the screen holds

**Files:**
- Modify: `Sources/Flock/Views/PaneLauncherOverlay.swift:136-168` (`PaneLauncherOverlay`)
- Modify: `Sources/Flock/Views/PaneCellView.swift` (the `PaneLauncherOverlay(...)` call from Task 5)
- Modify: `Tests/FlockChromeRender/PaneLauncherOverlayTests.swift`

**Interfaces:**
- Produces: `PaneLauncherOverlay.init(theme:entries:navigator:promptClearance:onLaunch:)` and `static func promptClearance(occupiedRows: Int, cellHeight: CGFloat?) -> CGFloat`.

- [ ] **Step 1: Write the failing tests**

In `PaneLauncherOverlayTests.swift`, give `Probe` a `var promptClearance: CGFloat = ChromeMetrics.Launcher.promptClearance` and pass it: `PaneLauncherOverlay(theme: theme, entries: entries, navigator: navigator, promptClearance: promptClearance, onLaunch: { _ in })`. Give `hostProbe` a `promptClearance: CGFloat = ChromeMetrics.Launcher.promptClearance` parameter passed into `Probe`. Add:

```swift
    /// The clearance follows the rows the screen holds: one row of breathing
    /// room above a four-row prompt at an 18pt cell is 90pt, and nothing on
    /// the overlay may answer a click inside it.
    func testTheClearanceFollowsTheOccupiedRows() async throws {
        XCTAssertEqual(PaneLauncherOverlay.promptClearance(occupiedRows: 4, cellHeight: 18), 90)
        XCTAssertEqual(
            PaneLauncherOverlay.promptClearance(occupiedRows: 0, cellHeight: 18), ChromeMetrics.Launcher.promptClearance,
            "never less than the fixed clearance"
        )
        XCTAssertEqual(
            PaneLauncherOverlay.promptClearance(occupiedRows: 4, cellHeight: nil), ChromeMetrics.Launcher.promptClearance,
            "no cell size yet: the fixed clearance"
        )

        let probe = try await hostProbe(entries: Self.entries, promptClearance: 90)
        defer { probe.window.close() }
        for y in stride(from: CGFloat(4), to: 90, by: 8) {
            XCTAssertTrue(probe.hitTest(CGPoint(x: Probe.size.width / 2, y: y)) === probe.terminal, "a button sits inside the clearance at y=\(y)")
        }
        XCTAssertFalse(probe.pointsClaimedByTheOverlay().isEmpty, "the buttons still draw below the clearance")
    }

    /// A four-row prompt in a dark and a light theme. Writes both PNGs when
    /// `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testAFourRowPromptKeepsTheButtonsBelowItInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let probe = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, promptClearance: 90
            )
            defer { probe.window.close() }
            let image = try snapshot(probe.window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("launcher-four-rows-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            let ground = hex(image, x: 2, y: 2)
            let scale = 2
            for y in stride(from: 4, to: 90 * scale, by: 16) {
                XCTAssertEqual(hex(image, x: image.pixelsWide / 2, y: y), ground, "\(theme.id): something drew inside the clearance at y=\(y)")
            }
        }
    }
```

- [ ] **Step 2: Run them to see them fail**

```bash
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/PaneLauncherOverlayTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "error:" | head -3
```

Expected: errors naming `promptClearance`.

- [ ] **Step 3: Implement**

In `PaneLauncherOverlay.swift`, add to `struct PaneLauncherOverlay`:

```swift
    /// Points kept clear at the top so the buttons never sit on the prompt.
    let promptClearance: CGFloat

    /// One row above whatever the screen holds, never less than the fixed
    /// clearance a fresh pane gets before its cell size is known.
    static func promptClearance(occupiedRows: Int, cellHeight: CGFloat?) -> CGFloat {
        guard let cellHeight, cellHeight > 0, occupiedRows > 0 else { return ChromeMetrics.Launcher.promptClearance }
        return max(ChromeMetrics.Launcher.promptClearance, CGFloat(occupiedRows + 1) * cellHeight)
    }
```

and change `.padding(.top, ChromeMetrics.Launcher.promptClearance)` to `.padding(.top, promptClearance)`. Declare `promptClearance` between `navigator` and `onLaunch` so the memberwise init order is `theme, entries, navigator, promptClearance, onLaunch`.

In `PaneCellView.swift`, the overlay call becomes:

```swift
                    PaneLauncherOverlay(
                        theme: theme, entries: HarnessRoster.detected(), navigator: NavigatorRoster.detected(),
                        promptClearance: PaneLauncherOverlay.promptClearance(
                            occupiedRows: viewModel.launcherOccupiedRows(pane.paneID), cellHeight: ghosttySurface.cellHeight
                        ),
                        onLaunch: { entry in Task { await LauncherSlots.launch(entry, in: pane.paneID, via: .click, on: viewModel) } }
                    )
```

Update the `PaneLauncherOverlay` doc comment's first sentence to say the overlay "only occupies the space below the rows the screen holds, via its own top spacer".

- [ ] **Step 4: Run the overlay tests with PNG output, then look at the PNGs**

```bash
mkdir -p build/render
TEST_RUNNER_FLOCK_CHROME_RENDER_DIR="$PWD/build/render" xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/PaneLauncherOverlayTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Test Case .*(passed|failed)|error:" | tail -12
ls build/render/launcher-four-rows-*
```

Open `build/render/launcher-four-rows-tokyoNight.png` and `launcher-four-rows-tokyoNightDay.png` with the Read tool and state plainly what is on them: the button row sits in the lower half, nothing in the top 90pt, the hint line (if any) at the bottom, and the colors read correctly in both schemes. If a button touches the top band, say so and fix the layout before continuing.

- [ ] **Step 5: Commit**

```bash
git add Sources/Flock/Views/PaneLauncherOverlay.swift Sources/Flock/Views/PaneCellView.swift Tests/FlockChromeRender/PaneLauncherOverlayTests.swift
Scripts/checks.sh 2>&1 | tail -3
git commit -m "launcher: keep the overlay below the rows the screen holds

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: End-to-end case, full suites, dev build hand-off

**Files:**
- Create: `Tests/FlockUITests/LauncherTests.swift`
- Run: `Scripts/e2e.sh` (with Matt's OK), `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev`

- [ ] **Step 1: Write the e2e case**

```swift
import XCTest

/// ⌘2 on a fresh pane launches the second slot from a cold app launch, with
/// no menu ever opened. The harness name echoing in the pane is the proof;
/// the scratch session is torn down with the run, so nothing it started
/// survives.
final class LauncherTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    @MainActor
    func testCommandTwoLaunchesIntoAFreshPaneWithoutTheMenuBeingOpened() throws {
        let ids = session.seedIDs()
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.flock(socket: session.socketPath)
        XCTAssertTrue(app.flockElement("flock.canvas.pane.\(ids.p1)").waitForExistence(timeout: 60))

        clickElement(app, "flock.strip.newTab")
        let before = Set(try session.snapshot().allPaneIDs())
        let fresh = try session.snapshot(waitingFor: "a third tab with a new pane") { snapshot in
            Set(snapshot.allPaneIDs()).subtracting(before).count == 1
        }
        let newPane = try XCTUnwrap(Set(fresh.allPaneIDs()).subtracting(before).first)
        XCTAssertTrue(
            app.flockElement("flock.pane.launcher.claude").waitForExistence(timeout: 30),
            "the launcher never showed on the fresh pane \(newPane)"
        )

        app.typeKey("2", modifierFlags: .command)

        var text = ""
        assertEventually("⌘2 types the second slot's harness into \(newPane)", timeout: 15) {
            text = (try? self.session.paneText(newPane)) ?? ""
            return text.contains("claude")
        } describing: {
            "\(newPane) holds:\n\(text)"
        }
        // Whatever started is stopped here rather than left to the teardown.
        try session.mutate(#"{"id":"e2e-stop","method":"pane.send_keys","params":{"pane_id":"\#(newPane)","keys":["C-c"]}}"#)
    }
}
```

`allPaneIDs()` and `snapshot(waitingFor:)` are the names to look up in `HerdrGroundTruth.swift` and `ScratchSession.swift`; if the ground-truth type exposes pane ids per tab only, collect them with `tabIDs(inWorkspace:)` and `paneIDs(inTab:)` over the seed workspace. The slot order on the e2e machine is rt cd, claude, codex, so ⌘2 is claude; if `rt` is not on the test machine's PATH, ⌘1 is claude and the case should press "1".

- [ ] **Step 2: Ask Matt for the OK, then run e2e once**

Say: "The e2e run launches Flock-dev under XCUITest against a scratch herdr for about a minute. OK to run it now?" On yes:

```bash
Scripts/e2e.sh 2>&1 | rg -n "Test Case .*(passed|failed)|error:|Executed" | tail -20
```

Expected: `LauncherTests` passes along with the existing suite. If the launcher button never appears, read `/usr/bin/log show --predicate 'subsystem == "dev.mattstack.flock" AND category == "launcher"' --last 10m` for the press and herdr's answer.

- [ ] **Step 3: Run the three CI suites**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Executed|failed" | tail -3
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd 2>&1 | rg -n "Executed|failed" | tail -3
Scripts/checks.sh 2>&1 | tail -3
```

Expected: `0 failures` twice and `all checks ok`.

- [ ] **Step 4: Commit and build the dev app**

```bash
git add Tests/FlockUITests/LauncherTests.swift
xcodegen && Scripts/checks.sh 2>&1 | tail -1
git commit -m "e2e: ⌘2 launches into a fresh pane from a cold launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev 2>&1 | tail -3
```

Tell Matt: "New dev build is ready: click the New build · Restart pill in Flock Dev. Checklist: (1) new tab shows the launcher once the prompt is up; (2) type `ls`, Ctrl-L: it returns; (3) type `clear`: it returns; (4) click rt cd, pick a folder: the pane clears and it returns; (5) restart Flock Dev: the same pane shows it again; (6) from that cold launch, ⌘2 with no menu opened launches claude."

- [ ] **Step 5: Open the PR**

```bash
git push -u origin launcher-at-prompt
gh pr create --title "Launcher shows at an empty prompt; ⌘ digits decided at press time" --body "$(cat <<'EOF'
The harness launcher is now a function of the pane's present state (bare screen, idle shell, nothing typed) instead of its history, so it returns after Ctrl-L, `clear`, `rt cd` and a Flock restart. ⌘1..⌘3 are bound once on the View items and decide at press time, which is what the log said was missing: fourteen days with no press reaching the Launch item.

Spec: docs/superpowers/specs/2026-10-07-pane-launcher-at-prompt-design.md
Plan: docs/superpowers/plans/2026-10-07-pane-launcher-at-prompt.md

- `PaneLauncherRegistry` rewritten as a state machine over rows, keystrokes and herdr's foreground answer
- `SessionViewModel` polls herdr only for candidate panes, with backoff; rt cd ends with a Ctrl-L
- Row counting runs for the surface's whole life at 2 Hz with a trailing re-check
- One launch function for click, key and palette, each logging one line
- Overlay clearance follows the rows the screen holds (render PNGs in both schemes)
- New e2e case: ⌘2 into a fresh pane from a cold launch

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Per Matt's PR rules: wait for CodeRabbit's review and address actionable findings, wait for CI green, then ask Matt before merging.

## Spike findings (2026-10-07)

- The Flock Dev run is deferred until Matt is at his desk. The spike build was delivered and its edits reverted; no log was collected.
- Tasks 1 to 6 proceeded on the plan's default constants: unknownHeightCap = 4, learningWindow = 2s, tallestPrompt = 8.
- The spike's checks move into Task 7's hand-off checklist: ⌘2 from a cold launch before and after opening Pane > Launch, row counts read from the launcher log, and the launcher's return after rt cd. The `C-l` send is exercised by the navigator flow itself.

## Spike findings, scratch run (2026-10-07)

Run against a scratch herdr session (`scratch-session.sh`, seeded with `seed-layout.sh`), reading screens with `pane.read` `visible`, which is the screen flock's surface repaints.

- A (⌘2 from a cold launch): not run. The XCUITest runner failed twice with "Timed out while enabling automation mode" on the origin/main build; UI automation needs an unlocked console session. B's in-app row log needs the app for the same reason. Both stay open for Matt's hand-off checklist.
- Prompt height: a fresh pane goes from 0 to 2 non-empty rows within 150ms (cwd line, prompt symbol line). The symbol changes with exit status; the count does not.
- Starship's scan-timeout warnings print above the prompt in a slow-to-scan directory on any prompt, not only at startup. Two warnings wrap to 3 rows at 119 columns, so warnings plus prompt is 5 rows, above `unknownHeightCap` (4). A pane first seen in that state waits for a drop; a learning window still takes 5 as the prompt (below `tallestPrompt`).
- `ls` in a large directory fills the screen (39 rows). `clear` drops it to 2.
- herdr's `pane.send_keys` rejects `C-l` (`invalid_key: unsupported key C-l`); only `C-c` has a `C-` spelling. `ctrl+l` is accepted and clears zsh (20 rows to 2). Task 4 sends `C-l`, so the navigator's clear fails silently as built.
- C: polling `pane.process_info` every 100ms through `sleep 1` never returned an empty `foreground_processes`. The one transitional answer at exit lists `starship` (rendering the prompt) in the shell's group; `isBusy` reads it as busy, so it is retried, never nil.
- D: `rt` is on the scratch shell's PATH. While the picker is up the foreground lists `rt-ui` (its pid is not the shell's, though its group is), so it reads busy. Escape returns the pane to a bare 2-row prompt on its own; the Ctrl-L after the navigator is not what makes the pane bare.
- Constants: unknownHeightCap 4, learningWindow 2s, tallestPrompt 8 hold for a plain prompt. Required change: the navigator sends `ctrl+l`.
