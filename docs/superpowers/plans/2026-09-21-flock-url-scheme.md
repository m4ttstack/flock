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
- Two repos, two histories: flock changes commit in
  `~/Documents/GitHub/flock/.worktrees/phase-0`, rt-tray changes in
  `~/Documents/GitHub/repo-tools`. Never one commit spanning both.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/FlockCore/URL/FlockURL.swift` (create) | Parse an incoming URL into a request. Pure, no AppKit. |
| `Tests/FlockCoreTests/FlockURLTests.swift` (create) | Every accepted and rejected URL form. |
| `Sources/FlockCore/ViewModels/SessionViewModel.swift` (modify) | Rename `focusFromChat(pane:)` to `focusPane(byID:)`. |
| `Tests/FlockCoreTests/SessionViewModelTests.swift` (modify) | Follow the rename. |
| `Sources/Flock/Views/ChatPeekView.swift` and any other caller (modify) | Follow the rename. |
| `project.yml` (modify) | `CFBundleURLTypes` per bundle. |
| `Sources/Flock/FlockApp.swift` (modify) | `.onOpenURL`, dispatch, window activation. |
| `rt-tray/Sources/FlockBridge.swift` (create, repo-tools) | Is flock running, and open a focus URL at it. |
| `rt-tray/Sources/TrayServer.swift` (modify, repo-tools) | Prefer flock in `POST /pane/focus`. |
| `rt-tray/Tests/FlockBridgeTests.swift` (create, repo-tools) | URL building and bundle choice. |

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
git add Sources/FlockCore/URL/FlockURL.swift Tests/FlockCoreTests/FlockURLTests.swift project.yml
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
                // Explicit, rather than relying on how the URL was opened:
                // the caller uses `open -g` so that a request flock decides
                // to ignore never steals the user's foreground app.
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
open ~/Library/Developer/Xcode/DerivedData/Flock-*/Build/Products/Debug/Flock.app
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
- Create: `rt-tray/Sources/FlockBridge.swift` (repo-tools)
- Create: `rt-tray/Tests/FlockBridgeTests.swift` (repo-tools)
- Modify: `rt-tray/Sources/TrayServer.swift:320-339` (repo-tools)

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2 at compile time. The URL string is the
  contract between the two repos, and it is `flock://focus?pane=<encoded id>`.
- Produces: `FlockBridge.shared.focusPane(_ paneId: String) -> Bool` (true
  when a running flock was asked, false when none is running),
  `FlockBridge.focusURL(paneId:scheme:) -> URL?` (pure, for the test).

- [ ] **Step 1: Write the failing tests**

Create `rt-tray/Tests/FlockBridgeTests.swift`:

```swift
import XCTest
@testable import rt_tray

/// The URL is the whole contract with flock, and the two live in different
/// repositories: nothing here catches a mismatch at compile time, so the
/// shape is pinned by these.
final class FlockBridgeTests: XCTestCase {
    func testTheFocusURLNamesTheVerbAndThePane() {
        let url = FlockBridge.focusURL(paneId: "w1:p2", scheme: "flock")

        XCTAssertEqual(url?.absoluteString, "flock://focus?pane=w1:p2")
    }

    /// A pane id is herdr's, not ours, and a character that means something
    /// in a query has to survive the trip rather than split the value.
    func testAPaneIDWithAQuerySeparatorIsEncoded() {
        let url = FlockBridge.focusURL(paneId: "w1:p2&pane=w9:p9", scheme: "flock")

        XCTAssertEqual(url?.absoluteString, "flock://focus?pane=w1:p2%26pane%3Dw9:p9")
    }

    func testTheDevBundleGetsTheDevScheme() {
        let url = FlockBridge.focusURL(paneId: "w1:p2", scheme: "flock-dev")

        XCTAssertEqual(url?.absoluteString, "flock-dev://focus?pane=w1:p2")
    }

    func testAnEmptyPaneIDMakesNoURL() {
        XCTAssertNil(FlockBridge.focusURL(paneId: "", scheme: "flock"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift test --filter FlockBridgeTests`

Expected: FAIL, "cannot find 'FlockBridge' in scope".

- [ ] **Step 3: Write the implementation**

Create `rt-tray/Sources/FlockBridge.swift`:

```swift
import AppKit
import Foundation

/// Asks a running flock to focus a pane.
///
/// flock knows which of its own windows holds a pane, so this needs none of
/// the process-ancestry guessing `HerdrBridge.focusPane` does for a pane
/// hosted by a terminal emulator. It is a one-way request: macOS URL handling
/// has no reply channel, so a running flock that does not know the pane is
/// indistinguishable from one that focused it.
enum FlockBridge {
    /// Prod first: when both copies are somehow running, the one the user
    /// installed wins.
    private static let bundles: [(id: String, scheme: String)] = [
        ("dev.mattstack.Flock", "flock"),
        ("dev.mattstack.Flock.dev", "flock-dev"),
    ]

    static var shared: FlockBridge.Type { FlockBridge.self }

    /// The scheme of whichever flock is running, or nil when none is.
    static func runningScheme() -> String? {
        bundles.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty }?.scheme
    }

    /// Pure, so the contract with flock can be tested without a running app.
    /// `queryItems` is what encodes a pane id containing a character that
    /// would otherwise end the value.
    static func focusURL(paneId: String, scheme: String) -> URL? {
        guard !paneId.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "focus"
        components.queryItems = [URLQueryItem(name: "pane", value: paneId)]
        return components.url
    }

    /// False means no flock is running and the caller should fall back.
    /// True means one was asked, not that it did anything.
    @discardableResult
    static func focusPane(_ paneId: String) -> Bool {
        guard let scheme = runningScheme(), let url = focusURL(paneId: paneId, scheme: scheme) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // flock raises itself in its own handler, so this must not also do
        // it: a request flock ignores would otherwise still steal the
        // foreground.
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift test --filter FlockBridgeTests`

Expected: PASS, 4 tests.

- [ ] **Step 5: Branch the tray's handler**

In `rt-tray/Sources/TrayServer.swift`, in the `POST /pane/focus` arm, put
flock in front of the existing call. Replace the `switch` with:

```swift
                    if FlockBridge.focusPane(req.paneId) {
                        self.sendResponse(connection: connection, status: 200, body: "{\"ok\":true,\"focused\":true}")
                    } else {
                        switch HerdrBridge.shared.focusPaneById(req.paneId) {
                        case .focused:
                            self.sendResponse(connection: connection, status: 200, body: "{\"ok\":true,\"focused\":true}")
                        case .notFound:
                            self.sendResponse(connection: connection, status: 404, body: "{\"ok\":false,\"error\":\"pane not found\"}", path: path)
                        case .herdrUnavailable:
                            self.sendResponse(connection: connection, status: 500, body: "{\"ok\":false,\"error\":\"herdr unavailable\"}", path: path)
                        }
                    }
```

And replace the comment above it:

```swift
                // The rt daemon's pane:focus verb routes here. A running
                // flock is asked first and answers for its own windows; with
                // no flock, this falls back to focusing herdr and hunting for
                // the terminal emulator hosting the pane, which is the only
                // thing herdr's own API makes possible.
```

- [ ] **Step 6: Build the tray and run its suite**

Run: `cd ~/Documents/GitHub/repo-tools/rt-tray && swift build && swift test`

Expected: both PASS.

- [ ] **Step 7: Check it by hand, both ways**

With flock running, from a terminal:

```bash
curl -s -X POST localhost:<tray port>/pane/focus -d '{"paneId":"<a real pane id>"}'
```

Expected: flock comes forward on that pane; the response is
`{"ok":true,"focused":true}`.

Then quit flock and repeat with a pane visible in herdr under Ghostty.
Expected: Ghostty comes forward, exactly as before this change.

Read the tray port from `~/.rt/logs/tray.*.log` or the tray's own health
endpoint rather than assuming one.

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/GitHub/repo-tools
git add rt-tray/Sources/FlockBridge.swift rt-tray/Tests/FlockBridgeTests.swift rt-tray/Sources/TrayServer.swift
git commit -m "tray: ask flock to focus a pane when flock is running

flock knows which of its windows holds a pane, so it needs none of the
process-ancestry hunting a terminal-emulator-hosted pane does. That path stays
for when flock is not running."
```

---

## Self-review notes

**Spec coverage.** URL shape: Task 1. What flock does on receipt, including
herdr staying in step through `jumpToHerdr`: Task 2 step 4, reusing the
existing method. Unknown pane does nothing: Task 1 refuses malformed input,
and the reused method's own guard covers a stale id (Task 2 step 6 checks it
by hand). Who decides between flock and Ghostty: Task 3. No reply: no task
needed, it is the absence of one. Security posture: Global Constraints. The
two-bundle wrinkle: Task 2 step 3 and Task 3's bundle list. Degrading table:
every row maps to Task 3's branch or the reused method's guard.

**One spec detail sharpened here.** The spec says the tray uses `open -g`;
the plan uses `NSWorkspace.OpenConfiguration` with `activates = false`, which
is the same intent from inside a Swift app rather than by shelling out, and
avoids a process spawn per focus.

**Not covered by any test, by nature.** Window activation, the running-app
check, and the two-bundle handler choice all need a real machine. Steps 6 and
7 of Tasks 2 and 3 are hand checks, and they are the gate for this feature.
