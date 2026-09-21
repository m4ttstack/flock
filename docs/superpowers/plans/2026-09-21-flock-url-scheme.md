# Flock URL Scheme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an outside program focus a flock pane by opening
`flock://focus?pane=<id>`, so rt stops guessing which window hosts a pane by
walking the process tree.

**Architecture:** flock registers a URL scheme and handles it in SwiftUI's
`.onOpenURL`, which has the session view model in scope where the app delegate
does not. Parsing is a pure function in FlockCore. The focus itself already
exists (`SessionViewModel.focusFromChat(pane:)`, built for chat's jump verb),
so this task renames it to something caller-neutral and reuses it. rt-tray
gains one branch: flock when it is running, the existing herdr plus ancestry
path when it is not.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, xcodegen (flock);
Swift + Network.framework (rt-tray).

**Spec:** `docs/superpowers/specs/2026-09-21-flock-url-scheme-design.md`

## Global Constraints

- The scheme carries only non-destructive, user-visible verbs. Never input
  injection, never anything that runs a command, never anything that changes
  a pane's contents or the session's layout.
- An unknown pane id does nothing, silently. No error UI, no toast.
- flock is never launched by a focus request. The tray checks first.
- The prod bundle (`dev.mattstack.Flock`) registers `flock`; the dev bundle
  (`dev.mattstack.Flock.dev`) registers `flock-dev`. Never both in one bundle.
- No comment in source may cite a task number, a review finding, or this plan.
- No em dashes or en dashes anywhere, including commit messages.
- Two repos, two histories, and never one commit spanning both. flock
  changes commit in `~/Documents/GitHub/flock/.worktrees/phase-0`.
- **The rt-tray half does not go in the shared repo-tools checkout.** That
  checkout is what the dev-mode `rt` wrapper executes and other sessions
  work in, and it is not always on `main`. Take an rt worktree for Task 3
  (`EnterWorktree`, name mode) and run `git branch --show-current` before
  the first edit either way.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/FlockCore/URL/FlockURL.swift` (create) | Parse an incoming URL into a request. Pure, no AppKit. |
| `Tests/FlockCoreTests/FlockURLTests.swift` (create) | Every accepted and rejected URL form. |
| `Sources/FlockCore/ViewModels/SessionViewModel.swift` (modify) | Rename `focusFromChat(pane:)` to `focusPane(byID:)`. |
| `Tests/FlockCoreTests/SessionViewModelTests.swift` (modify) | Follow the rename. |
| `Sources/Flock/Views/PaneCellView.swift:516` (modify) | The one caller of the renamed method. |
| `project.yml` (modify) | `CFBundleURLTypes` per bundle. |
| `Sources/Flock/FlockApp.swift` (modify) | `.onOpenURL`, dispatch, window activation. |
| `rt-tray/Sources-core/Flock/FlockFocusURL.swift` (create, repo-tools) | Pure: the bundle-to-scheme table, choosing a scheme from a set of running bundle ids, and building the URL. No AppKit. |
| `rt-tray/Tests/MattstackCoreChecks/FlockFocusURLChecks.swift` (create, repo-tools) | Checks for the above. |
| `rt-tray/Sources/FlockBridge.swift` (create, repo-tools) | The AppKit binding: which bundles are running, and opening the URL. |
| `rt-tray/Sources/HerdrBridge.swift:213` (modify, repo-tools) | Try flock first inside `focusPane(_:)`, the one function every focus path funnels through. |

---

## Task 1: Parse the URL

**Files:**
- Create: `Sources/FlockCore/URL/FlockURL.swift`
- Test: `Tests/FlockCoreTests/FlockURLTests.swift`

**Interfaces:**
- Consumes: `PaneID` (existing, `Sources/FlockCore/Herdr/HerdrModel.swift`).
- Produces: `FlockURL.scheme: String`, `FlockURL.devScheme: String`,
  `FlockURL.Request` (enum, one case `focusPane(PaneID)`),
  `FlockURL.parse(_ url: URL) -> FlockURL.Request?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlockCoreTests/FlockURLTests.swift`:

```swift
import XCTest
@testable import FlockCore

/// The one door an outside program can knock on. Everything that is not
/// exactly a focus request has to be refused rather than guessed at: this
/// parses input from any process on the machine, including a web page the
/// user merely clicked.
final class FlockURLTests: XCTestCase {
    private func parse(_ string: String) -> FlockURL.Request? {
        guard let url = URL(string: string) else { return nil }
        return FlockURL.parse(url)
    }

    func testAFocusRequestCarriesItsPaneID() {
        XCTAssertEqual(parse("flock://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    /// herdr pane ids contain a colon, so callers are expected to encode it.
    /// Both forms have to land on the same pane.
    func testAPercentEncodedPaneIDDecodesToTheSameID() {
        XCTAssertEqual(parse("flock://focus?pane=w1%3Ap2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    /// The dev bundle registers its own scheme so two installed copies cannot
    /// fight over one handler, and it answers the same requests.
    func testTheDevSchemeIsAcceptedToo() {
        XCTAssertEqual(parse("flock-dev://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    func testTheSchemeIsMatchedCaseInsensitively() {
        XCTAssertEqual(parse("FLOCK://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    func testAnotherAppsSchemeIsRefused() {
        XCTAssertNil(parse("herdr://focus?pane=w1:p2"))
        XCTAssertNil(parse("https://focus?pane=w1:p2"))
    }

    /// The shape allows more verbs later; today anything but focus is refused
    /// rather than treated as one.
    func testAnUnknownVerbIsRefused() {
        XCTAssertNil(parse("flock://send?pane=w1:p2"))
        XCTAssertNil(parse("flock://?pane=w1:p2"))
    }

    func testAFocusRequestWithNoPaneIsRefused() {
        XCTAssertNil(parse("flock://focus"))
        XCTAssertNil(parse("flock://focus?pane="))
        XCTAssertNil(parse("flock://focus?tab=w1:t1"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Documents/GitHub/flock/.worktrees/phase-0 && xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/FlockURLTests`

Expected: FAIL, "cannot find 'FlockURL' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/FlockCore/URL/FlockURL.swift`:

```swift
import Foundation

/// The only way into flock from outside the app.
///
/// Every value here arrives from a process flock does not control, so parsing
/// refuses anything it does not recognise outright rather than reading past
/// it. The shape leaves room for more verbs; the rule that they stay
/// non-destructive is in this feature's spec, not enforceable here.
public enum FlockURL {
    /// The prod bundle's scheme.
    public static let scheme = "flock"
    /// The dev bundle's. Two installed copies would otherwise register the
    /// same scheme, and macOS picks ONE handler for a scheme with no
    /// guarantee it is the copy that is running.
    public static let devScheme = "flock-dev"

    public enum Request: Equatable, Sendable {
        case focusPane(PaneID)
    }

    public static func parse(_ url: URL) -> Request? {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == devScheme else {
            return nil
        }
        // `URLComponents` rather than `url.query`: it is what decodes the
        // percent-encoding a colon in a pane id needs.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.host?.lowercased() == "focus" else { return nil }
        guard
            let pane = components.queryItems?.first(where: { $0.name == "pane" })?.value,
            !pane.isEmpty
        else { return nil }
        return .focusPane(PaneID(rawValue: pane))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/FlockURLTests`

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/GitHub/flock/.worktrees/phase-0
git add Sources/FlockCore/URL/FlockURL.swift Tests/FlockCoreTests/FlockURLTests.swift
git commit -m "flock url: parse a focus request, refuse everything else"
```

---

## Task 2: Register the scheme and act on it

**Files:**
- Modify: `project.yml` (the `Flock` and `Flock-dev` target `info.properties`)
- Modify: `Sources/Flock/FlockApp.swift` (the `WindowGroup` content)
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift:435`
- Modify: `Tests/FlockCoreTests/SessionViewModelTests.swift` (rename only)
- Modify: every existing caller of `focusFromChat(pane:)`

**Interfaces:**
- Consumes: `FlockURL.parse(_:)` from Task 1.
- Produces: `SessionViewModel.focusPane(byID: PaneID) async` (the rename of
  `focusFromChat(pane:)`; same body, same behaviour).

- [ ] **Step 1: Rename the focus method and its callers**

The method already exists and already does the whole job, including the
no-op on a pane the model does not have. It only needs a name that does not
claim one caller. In `Sources/FlockCore/ViewModels/SessionViewModel.swift`,
change the declaration at line 435 and its doc comment:

```swift
    /// Focuses a pane named on its own, with no workspace or tab alongside
    /// it: chat's jump verb and an outside program's focus request both
    /// arrive that way. The workspace and tab come from the pane's OWN
    /// record rather than from whatever is selected now, and all three are
    /// focused in the same order `jumpToAttentionToast` uses.
    ///
    /// A pane the model no longer has (closed since the request was made)
    /// sends no request at all, rather than jumping a workspace or tab to
    /// nowhere.
    public func focusPane(byID id: PaneID) async {
        guard let record = model?.panes[id] else { return }
        await jumpToHerdr(workspace: record.workspaceID)
        await jumpToHerdr(tab: record.tabID)
        await jumpToHerdr(pane: record.paneID)
    }
```

Then update every caller:

```bash
cd ~/Documents/GitHub/flock/.worktrees/phase-0
grep -rn "focusFromChat" Sources Tests
```

Replace each `focusFromChat(pane: X)` with `focusPane(byID: X)`. Test names
that say `focusFromChat` become `focusPane` in the same edit.

- [ ] **Step 2: Run the core suite to verify the rename is complete**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests`

Expected: PASS, same count as before the rename. A compile error naming
`focusFromChat` means a caller was missed.

- [ ] **Step 3: Register the schemes**

In `project.yml`, add to the `Flock` target's `info.properties`:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: dev.mattstack.Flock.focus
            CFBundleURLSchemes: [flock]
```

And to the `Flock-dev` target's `info.properties`:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: dev.mattstack.Flock.dev.focus
            CFBundleURLSchemes: [flock-dev]
```

Each bundle registers exactly one scheme. Two bundles registering the same
scheme is the case this split exists to avoid.

- [ ] **Step 4: Handle the URL**

In `Sources/Flock/FlockApp.swift`, find the `WindowGroup("Flock")` scene and
add `.onOpenURL` to its content view, alongside the existing modifiers:

```swift
            .onOpenURL { url in
                guard case let .focusPane(pane) = FlockURL.parse(url) else { return }
                // Membership before activation, not after. `parse` validates
                // the URL's SHAPE only, and `focusPane(byID:)` does its own
                // model check asynchronously, so activating first would raise
                // the window for a pane that no longer exists and then do
                // nothing... a visible side effect where the spec promises
                // silence.
                guard viewModel.model?.panes[pane] != nil else { return }
                // Explicit, rather than relying on how the URL was opened:
                // the caller opens it WITHOUT activating, so that a request
                // flock decides to ignore never steals the foreground.
                NSApp.activate(ignoringOtherApps: true)
                Task { await viewModel.focusPane(byID: pane) }
            }
```

`.onOpenURL` rather than the app delegate's `application(_:open:)`: the
session view model is `@State` on `FlockApp` and is in scope here, where the
delegate cannot reach it without a global.

- [ ] **Step 5: Build and run both suites**

Run:
```bash
cd ~/Documents/GitHub/flock/.worktrees/phase-0
xcodegen
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS'
```

Expected: both PASS. Run FlockChromeRender unscoped; a scoped run hides a
crash in a sibling test.

- [ ] **Step 6: Check it by hand**

This is the part no test covers. Build and launch, then from a terminal:

```bash
cd ~/Documents/GitHub/flock/.worktrees/phase-0
bash Scripts/build.sh
open "$(xcodebuild -scheme Flock -configuration Debug -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}')/Flock.app"
# With flock in the background and a different app in front, using a pane id
# from flock's own rail:
open -g "flock://focus?pane=<a real pane id>"
```

Expected: flock comes forward with that pane's workspace and tab selected and
that pane focused. Then confirm a stale id does nothing:

```bash
open -g "flock://focus?pane=w9:p99"
```

Expected: nothing happens, no error, no window change.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/GitHub/flock/.worktrees/phase-0
git add -A
git commit -m "flock url: focus a pane from an outside program

Renames focusFromChat to focusPane(byID:), since chat is no longer its only
caller. The body is unchanged: it already resolved the workspace and tab from
the pane's own record and already did nothing for a pane the model had lost."
```

---

## Task 3: The tray prefers flock

**Files:**
- Create: `rt-tray/Sources-core/Flock/FlockFocusURL.swift` (repo-tools)
- Create: `rt-tray/Tests/MattstackCoreChecks/FlockFocusURLChecks.swift` (repo-tools)
- Modify: `rt-tray/Tests/MattstackCoreChecks/AllChecks.swift:3` (repo-tools)
- Create: `rt-tray/Sources/FlockBridge.swift` (repo-tools)
- Modify: `rt-tray/Sources/HerdrBridge.swift:213-228` (repo-tools)

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2 at compile time. The URL string is the
  contract between the two repos, and it is `flock://focus?pane=<encoded id>`.
- Produces: `FlockFocusURL.scheme(forRunningBundleIDs: Set<String>) -> String?`
  and `FlockFocusURL.url(paneId: String, scheme: String) -> URL?` in
  `MattstackCore`; `FlockBridge.focusPane(_ paneId: String) -> Bool` in the
  app target.

**Why the branch goes in `HerdrBridge.focusPane(_:)`.** Four call sites reach
the ancestry walk, not one: `TrayServer.swift:329` and
`NotificationManager.swift:406` and `:417` through `focusPaneById`, and
`ProcessPanelController.swift:415` directly. All four funnel through
`focusPane(_ pane: HerdrPane)`, so one branch there covers every entry point.
Branching the HTTP handler instead would leave notification clicks guessing,
and those are half of why this feature exists.

**Why `focusPaneById`'s herdr lookup stays in front of it.** That lookup is
what still answers "does this pane exist", which the daemon turns into a CLI
error (`lib/daemon/handlers/pane.ts:399` fails the command on `ok: false`).
The URL scheme cannot answer it, so the tray keeps answering it from herdr.

- [ ] **Step 1: Write the failing checks**

Create `rt-tray/Tests/MattstackCoreChecks/FlockFocusURLChecks.swift`:

```swift
import Foundation
import MattstackCore

let flockFocusURLChecks: [Check] = [
    Check("the focus URL names the verb and the pane") { c in
        let url = FlockFocusURL.url(paneId: "w1:p2", scheme: "flock")
        c.expectEqual(url?.absoluteString, "flock://focus?pane=w1:p2")
    },
    // A pane id is herdr's, not ours. A character that means something in a
    // query has to survive the trip rather than split the value.
    Check("a pane id carrying a query separator is encoded") { c in
        let url = FlockFocusURL.url(paneId: "w1:p2&pane=w9:p9", scheme: "flock")
        c.expectEqual(url?.absoluteString, "flock://focus?pane=w1:p2%26pane%3Dw9:p9")
    },
    Check("an empty pane id makes no URL") { c in
        c.expect(FlockFocusURL.url(paneId: "", scheme: "flock") == nil, "empty id must not build a URL")
    },
    Check("a running prod flock picks the prod scheme") { c in
        c.expectEqual(FlockFocusURL.scheme(forRunningBundleIDs: ["dev.mattstack.Flock"]), "flock")
    },
    Check("a running dev flock picks the dev scheme") { c in
        c.expectEqual(FlockFocusURL.scheme(forRunningBundleIDs: ["dev.mattstack.Flock.dev"]), "flock-dev")
    },
    // Two installed copies both register a scheme, so the tray has to choose
    // rather than let macOS pick a handler for it.
    Check("both running prefers prod") { c in
        let running: Set<String> = ["dev.mattstack.Flock.dev", "dev.mattstack.Flock"]
        c.expectEqual(FlockFocusURL.scheme(forRunningBundleIDs: running), "flock")
    },
    Check("no flock running picks no scheme") { c in
        c.expect(FlockFocusURL.scheme(forRunningBundleIDs: ["com.mitchellh.ghostty"]) == nil,
                 "a machine with no flock must fall back, not build a URL")
    },
]
```

Register it in `rt-tray/Tests/MattstackCoreChecks/AllChecks.swift` by adding
`+ flockFocusURLChecks` to the end of the `allChecks` expression on line 3.
The registry is explicit by design; a new file that is not added runs nothing
and reports nothing.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift test`

Expected: FAIL to compile, "cannot find 'FlockFocusURL' in scope".

- [ ] **Step 3: Write the pure implementation**

Create `rt-tray/Sources-core/Flock/FlockFocusURL.swift`:

```swift
import Foundation

/// The contract with flock's URL scheme: which scheme to use, and how to
/// build a focus request.
///
/// Pure, and in core rather than the app target, for the same reason
/// `TerminalResolver` is: the decisions are worth checking and AppKit is not
/// available to a check. `FlockBridge` binds this to the real running-app
/// list.
///
/// flock lives in another repository, so nothing here fails to compile when
/// that side changes. These checks are the only thing pinning the shape.
public enum FlockFocusURL {
    /// Prod first: two installed copies each register their own scheme, and
    /// when both are somehow running the one the user installed wins.
    public static let bundles: [(id: String, scheme: String)] = [
        ("dev.mattstack.Flock", "flock"),
        ("dev.mattstack.Flock.dev", "flock-dev"),
    ]

    /// The scheme for whichever flock is running, or nil when none is, which
    /// is the caller's signal to fall back rather than to launch one.
    public static func scheme(forRunningBundleIDs running: Set<String>) -> String? {
        bundles.first { running.contains($0.id) }?.scheme
    }

    /// `URLComponents` rather than string building: it is what encodes a pane
    /// id containing a character that would otherwise end the value.
    public static func url(paneId: String, scheme: String) -> URL? {
        guard !paneId.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "focus"
        components.queryItems = [URLQueryItem(name: "pane", value: paneId)]
        return components.url
    }
}
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift test`

Expected: PASS, with seven more checks than before.

- [ ] **Step 5: Write the AppKit binding**

Create `rt-tray/Sources/FlockBridge.swift`:

```swift
import AppKit
import Foundation
import MattstackCore

/// Asks a running flock to focus a pane.
///
/// flock knows which of its own windows holds a pane, so this needs none of
/// the process-ancestry guessing `HerdrBridge.focusPane` does for a pane
/// hosted by a terminal emulator.
///
/// One way only: macOS URL handling has no reply channel. Whether the pane
/// exists is answered before this runs, by the herdr lookup in
/// `focusPaneById`, so nothing here needs an answer.
enum FlockBridge {
    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// False means no flock is running and the caller should fall back. True
    /// means one was asked, not that it did anything.
    @discardableResult
    static func focusPane(_ paneId: String) -> Bool {
        guard
            let scheme = FlockFocusURL.scheme(forRunningBundleIDs: runningBundleIDs()),
            let url = FlockFocusURL.url(paneId: paneId, scheme: scheme)
        else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        // flock raises itself inside its own handler, so this must not also
        // do it: a request flock decides to ignore would otherwise still
        // steal the user's foreground app.
        configuration.activates = false
        // Hopped to main for the same reason the terminal raise below this
        // in `HerdrBridge.focusPane` is: callers reach here from the
        // tray's connection queue, and AppKit is not owed a background
        // thread. The open is asynchronous either way, so this costs the
        // caller nothing.
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
        }
        TrayLog.info("asked flock to focus pane", ["pane_id": paneId, "scheme": scheme])
        return true
    }
}
```

- [ ] **Step 6: Branch inside `focusPane`**

In `rt-tray/Sources/HerdrBridge.swift`, `focusPane(_ pane: HerdrPane)` at line
213 currently focuses the workspace and tab through herdr, then hunts for a
terminal app to activate. Put flock in front of all of it:

```swift
    func focusPane(_ pane: HerdrPane) {
        // Every focus path funnels through here: the daemon's POST, both
        // notification click handlers, and the process panel. A running flock
        // answers for its own windows and sends its own workspace, tab and
        // pane focus, so nothing below needs to run.
        if FlockBridge.focusPane(pane.paneId) { return }

        run(["workspace", "focus", pane.workspaceId])
        run(["tab", "focus", pane.tabId])
        // Shell ancestry only reaches the terminal when the pane runs under
        // it; a daemon-hosted pane's shell hangs off the launchd-parented
        // herdr server, so fall back to walking up from an attach client.
        let terminalPid = Self.terminalAppPid(ancestorOf: pane.hostPid)
            ?? Self.terminalAppPidViaHerdrClient()
        if let terminalPid {
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid_t(terminalPid))?.activate(options: [.activateAllWindows])
            }
        } else {
            TrayLog.warn("no terminal found for herdr pane", ["pane_id": pane.paneId, "host_pid": pane.hostPid])
        }
    }
```

`focusPaneById` is left alone. Its `listPanes()` lookup runs first and still
returns `.notFound` for a pane herdr does not have, which is what keeps
`rt pane focus` reporting a stale id as an error rather than a success.

- [ ] **Step 7: Build the tray and run its suite**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift build && swift test`

Expected: both PASS.

- [ ] **Step 8: Check all four entry points by hand**

No test covers activation or the running-app check. With flock running:

```bash
# 1. the daemon route
curl -s -X POST localhost:<tray port>/pane/focus -d '{"paneId":"<a real pane id>"}'
```
Expected: flock comes forward on that pane; the response is
`{"ok":true,"focused":true}`.

```bash
# 2. a stale id, which must still be an error
curl -s -X POST localhost:<tray port>/pane/focus -d '{"paneId":"w9:p99"}'
```
Expected: 404 with `pane not found`, exactly as before this change.

3. Click a tray notification for a pane. Expected: flock comes forward.
4. Focus a pane from the tray's process panel. Expected: flock comes forward.

Then quit flock and repeat 1, 3 and 4 against a pane visible in herdr under
Ghostty. Expected: Ghostty comes forward, exactly as before.

Read the tray port from `~/.rt/logs/tray.*.log` or the tray's health endpoint
rather than assuming one.

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/GitHub/repo-tools
git add rt-tray/Sources-core/Flock/FlockFocusURL.swift \
        rt-tray/Tests/MattstackCoreChecks/FlockFocusURLChecks.swift \
        rt-tray/Tests/MattstackCoreChecks/AllChecks.swift \
        rt-tray/Sources/FlockBridge.swift \
        rt-tray/Sources/HerdrBridge.swift
git commit -m "tray: ask flock to focus a pane when flock is running

flock knows which of its windows holds a pane, so it needs none of the
process-ancestry hunting a terminal-emulator-hosted pane does. The branch sits
in focusPane, which every focus path funnels through, so notification clicks
and the process panel get it too rather than only the daemon's POST.

The herdr lookup in focusPaneById stays in front of it, so a pane herdr does
not have is still a 404 and rt pane focus still reports it."
```

---
## Self-review notes

**Spec coverage.** URL shape: Task 1. What flock does on receipt, including
herdr staying in step through `jumpToHerdr`: Task 2 step 4, reusing the
existing method. Unknown pane: Task 1 refuses malformed input, the reused
method's guard covers a stale id inside flock, and Task 3's herdr lookup is
what keeps the CLI reporting one as an error. Who decides between flock and
Ghostty, at all four entry points: Task 3 step 6. No reply, and why it costs
nothing: Task 3's interfaces block and step 8's stale-id check. Security
posture: Global Constraints. The two-bundle wrinkle: Task 2 step 3 registers
one scheme per bundle, Task 3 step 3 chooses between them. Degrading table:
every row maps to Task 3's branch, Task 3's herdr lookup, or the reused
method's guard.

**One spec detail sharpened here.** The spec says the tray uses `open -g`;
the plan uses `NSWorkspace.OpenConfiguration` with `activates = false`, which
is the same intent from inside a Swift app rather than by shelling out, and
avoids a process spawn per focus.

**Three things the first round of review corrected, kept here so they are not
reintroduced.** The rt-tray tests first went in `rt-tray/Tests/` with
`@testable import rt_tray`, which compiles into nothing: that package's test
targets are path-scoped and its pure logic lives in `Sources-core` beside a
checks file, the way `TerminalResolver` does. The branch first went in
`TrayServer`'s HTTP handler, which would have left notification clicks and
the process panel still guessing. And the spec first claimed the daemon only
logs the focus outcome, which is false: it fails the command on `ok: false`,
so a stale id would have gone from a CLI error to a silent success.

**Not covered by any test, by nature.** Window activation, the running-app
check, and the two-bundle handler choice all need a real machine. Task 2
step 6 and Task 3 step 8 are hand checks, and they are the gate for this
feature.
