# Profiles and herdr Server Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let flock keep several profiles, each with its own preferences, its own herdr server and its own id-keyed state per server, and switch between them (or change a profile's server) in place, without quitting.

**Architecture:** Everything `FlockApp.init` builds per socket and per `UserDefaults` moves into one `FlockSession`. A `ProfileSessionController` (FlockCore, generic over the session) owns the current session and runs a switch as guard, teardown, save, rebuild. Profiles and their suite names live in FlockCore (`ProfileStore`, `ProfileSuites`); server addressing and `herdr session list` parsing live in FlockCore too. Settings gains a Server row (herdr tab) and a Profiles tab; the Flock menu gains a Profile submenu.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Observation, XCTest, CryptoKit (SHA-256 for the socket key), xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-20-profiles-and-herdr-servers-design.md`

## Global Constraints

- Public repo: no employer, customer, host, ticket id or private link in code, fixtures, docs or commit messages. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration or history.
- Tests stay hermetic: no test spawns rt, herdr, herdr-chat or deck, reads `~/.mattstack`, or reaches the network. Stores take injected `UserDefaults` and sources.
- Never `herdr server stop`, never `pane.scroll`, never `layout.apply` on live panes. flock never stops or deletes herdr sessions.
- Child processes get `ToolPath.childEnvironment()`, which carries the current session's socket in `HERDR_SOCKET_PATH`. The one exception is the server launcher (Task 5).
- `@MainActor` test classes: statics read in `setUp`/`tearDown` are `nonisolated`.
- Switching never quits flock. One window; no multi-window work.
- With no profile list stored and no `HERDR_SOCKET_PATH`, flock behaves exactly as today (Default profile, default socket, `UserDefaults.standard`).
- `HERDR_SOCKET_PATH` set in flock's own environment wins: flock uses it with the current profile's preferences and id-keyed state from the fixed suite `<bundle id>.override`; the picker and profile switching are disabled; no profile's saved server or `knownSockets` changes.
- Default profile id is `default`, name `Default`. Suites: `<bundle id>.profile.<id>` for preferences, `<bundle id>.profile.<id>.server.<key>` for id-keyed state, `<key>` the first 12 lowercase hex chars of SHA-256 of the lexically normalized socket path. Default on the default socket uses `UserDefaults.standard` for both.
- Socket paths are normalized lexically everywhere (leading `~` expanded, `.` and `..` resolved, trailing `/` dropped), never by resolving symlinks: resolution changes with whether the socket exists.
- Nothing (current profile id, a profile's server) is saved until the two-Flocks guard passes.
- Server starts go through `HerdrServerLauncher` (setsid, stdio on /dev/null, `HERDR_MACOS_SERVER_CONTEXT=user`, no `RT_BATCH`, cwd home).
- Run `xcodegen` after adding or removing files; run `Scripts/checks.sh` after `git add`.
- Every build and test uses `-derivedDataPath build/dd` inside the worktree (a path containing "GitHub" trips the worktree guard). Render directories are absolute and created first: `RENDER=$PWD/build/renders/<name>; mkdir -p $RENDER`. Run only the tests for the code you touched.
- Shared test fixtures, spelled out in each task that uses them: home directory `/Users/someone`; default socket `/Users/someone/.config/herdr/herdr.sock`; named socket `/Users/someone/.config/herdr/sessions/acme/herdr.sock`.

## Review Focus

1. **A second switch while one is in flight** (two profile clicks in a row): one switch at a time, never two live sessions. Pinned in Task 4 (`testASwitchRequestedMidSwitchWaitsItsTurn`).
2. **Switching with live transient UI** (rt modal open, parked panes, a view attaching a pane late): teardown detaches every surface, parked ones included, ends rt watches and the background timer, and refuses later attaches. Pinned in Task 3 (`testShutdownDetachesParkedSurfacesAndEndsRtWatches`, `testNoAttachAfterShutdown`).
3. **A socket path typed with `~`, `.`, `..` or a trailing slash, or the default path typed by hand**: resolves to the same server and the same suite key as the menu entry. Pinned in Task 1 (`testSpellingsOfOneServerResolveAlike`) and Task 2 (`testSocketKeyIgnoresSpelling`).
4. **Blank, duplicate or odd names**: profile names trim and must be non-empty (duplicates allowed, ids differ); session names match `[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}` and are not `default`, so `.` and `..` cannot escape the sessions folder. Pinned in Task 1 (`testServerNameValidation`) and Task 2 (`testCreateRejectsABlankName`).
5. **Deleting a profile whose server is still running**: its suites go, its herdr server is left alone. Pinned in Task 2 (`testDeleteRemovesEverySuiteAndNothingElse`).

---

### Task 1: Server addresses and the session list

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrServerAddress.swift`
- Create: `Sources/FlockCore/Herdr/HerdrSessionList.swift`
- Test: `Tests/FlockCoreTests/HerdrServerAddressTests.swift`
- Test: `Tests/FlockCoreTests/HerdrSessionListTests.swift`

**Interfaces:**
- Produces:
  - `public enum HerdrServerAddress: Equatable, Sendable { case defaultServer; case named(String); case custom(String) }`
  - `public static func normalize(_ path: String, home: String) -> String` (lexical: leading `~` becomes `home`, `.` and `..` components resolved, duplicate and trailing `/` dropped; no filesystem access)
  - `public init(socketPath: String, home: String)` (normalizes first; `<home>/.config/herdr/herdr.sock` is `.defaultServer`, `<home>/.config/herdr/sessions/<name>/herdr.sock` with a valid name is `.named(name)`, anything else `.custom(normalizedPath)`)
  - `public func socketPath(home: String) -> String`
  - `public var label: String` (`"default"`, the name, or the custom path's parent directory name; replaces `FlockApp.sessionLabel(fromSocketPath:)`)
  - `public var isStartable: Bool` (false only for `.custom`)
  - `public static func isValidSessionName(_ name: String) -> Bool` (`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$` and not `default`)
  - `public struct HerdrSessionEntry: Equatable, Sendable { public let name: String; public let isRunning: Bool; public let socketPath: String; public let isDefault: Bool; public init(name:isRunning:socketPath:isDefault:) }`
  - `public enum HerdrSessionList { public static func parse(_ stdout: Data) -> [HerdrSessionEntry]? }` (nil for output that is not the shape below)

`herdr session list --json` answers (checked against herdr on 2026-10-20):

```json
{"sessions":[{"default":true,"name":"default","running":true,"session_dir":"/Users/someone/.config/herdr","socket_path":"/Users/someone/.config/herdr/herdr.sock"},{"default":false,"name":"acme","running":false,"session_dir":"/Users/someone/.config/herdr/sessions/acme","socket_path":"/Users/someone/.config/herdr/sessions/acme/herdr.sock"}]}
```

- [ ] **Step 0: Prepare the worktree**

Copy the gitignored build inputs in from the main checkout and init the ghostty submodule:

```bash
cp -cR /Users/matt/Documents/GitHub/flock/Vendor/GhosttyKit.xcframework Vendor/
cp -cR /Users/matt/Documents/GitHub/flock/Vendor/Sparkle Vendor/
cp -c /Users/matt/Documents/GitHub/flock/Vendor/libghostty.version Vendor/
cp -c /Users/matt/Documents/GitHub/flock/Sources/Flock/Resources/herdr-chat* Sources/Flock/Resources/
git submodule update --init Vendor/ghostty
```

Expected: `ls Vendor` shows `GhosttyKit.xcframework` and `Sparkle`.

- [ ] **Step 1: Write the failing tests**

```swift
final class HerdrServerAddressTests: XCTestCase {
    private let home = "/Users/someone"
    private let defaultSocket = "/Users/someone/.config/herdr/herdr.sock"
    private let acmeSocket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"

    func testTheDefaultSocketIsTheDefaultServer() {
        XCTAssertEqual(HerdrServerAddress(socketPath: defaultSocket, home: home), .defaultServer)
    }
    func testASessionsSocketIsNamed() {
        XCTAssertEqual(HerdrServerAddress(socketPath: acmeSocket, home: home), .named("acme"))
    }
    func testAnythingElseIsCustom() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/tmp/acme/x.sock", home: home), .custom("/tmp/acme/x.sock"))
    }
    func testSpellingsOfOneServerResolveAlike() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "~/.config/herdr/herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/./herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/sessions/x/../acme/herdr.sock", home: home), .named("acme"))
        XCTAssertEqual(HerdrServerAddress.normalize("/tmp//acme/x.sock/", home: home), "/tmp/acme/x.sock")
    }
    func testADotDotSessionIsNotNamed() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/sessions/../herdr.sock", home: home), .defaultServer)
    }
    func testSocketPathRoundTrips() {
        XCTAssertEqual(HerdrServerAddress.named("acme").socketPath(home: home), acmeSocket)
        XCTAssertEqual(HerdrServerAddress.defaultServer.socketPath(home: home), defaultSocket)
    }
    func testLabels() {
        XCTAssertEqual(HerdrServerAddress.defaultServer.label, "default")
        XCTAssertEqual(HerdrServerAddress.named("acme").label, "acme")
        XCTAssertEqual(HerdrServerAddress.custom("/tmp/acme/x.sock").label, "acme")
    }
    func testOnlyCustomIsNotStartable() {
        XCTAssertTrue(HerdrServerAddress.defaultServer.isStartable)
        XCTAssertTrue(HerdrServerAddress.named("acme").isStartable)
        XCTAssertFalse(HerdrServerAddress.custom("/tmp/x.sock").isStartable)
    }
    func testServerNameValidation() {
        XCTAssertTrue(HerdrServerAddress.isValidSessionName("acme-demo_1.2"))
        for bad in ["", " ", "a b", "a/b", ".", "..", ".hidden", "default", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrServerAddress.isValidSessionName(bad), bad)
        }
    }
}
```

`HerdrSessionListTests`: `testParsesEachSession` (the JSON above gives `[HerdrSessionEntry(name: "default", isRunning: true, socketPath: "/Users/someone/.config/herdr/herdr.sock", isDefault: true), HerdrSessionEntry(name: "acme", isRunning: false, socketPath: "/Users/someone/.config/herdr/sessions/acme/herdr.sock", isDefault: false)]`), `testRejectsOutputThatIsNotTheList` (`Data("nope".utf8)` and `Data(#"{"sessions":3}"#.utf8)` give nil).

- [ ] **Step 2: Regenerate and run them to see them fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrServerAddressTests -only-testing:FlockCoreTests/HerdrSessionListTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'HerdrServerAddress' in scope`.

- [ ] **Step 3: Implement both files to the interfaces above**

- [ ] **Step 4: Run the tests again**

Same command. Expected: `** TEST SUCCEEDED **`, with both classes' tests listed as executed.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Herdr/HerdrServerAddress.swift Sources/FlockCore/Herdr/HerdrSessionList.swift Tests/FlockCoreTests/HerdrServerAddressTests.swift Tests/FlockCoreTests/HerdrSessionListTests.swift
Scripts/checks.sh
git commit -m "herdr server addresses and the session list"
```

---

### Task 2: Profiles and their suites

**Files:**
- Create: `Sources/FlockCore/Profiles/FlockProfile.swift`
- Create: `Sources/FlockCore/Profiles/ProfileSuites.swift`
- Create: `Sources/FlockCore/Profiles/ProfileStore.swift`
- Test: `Tests/FlockCoreTests/ProfileSuitesTests.swift`
- Test: `Tests/FlockCoreTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: `HerdrServerAddress.normalize(_:home:)` (Task 1).
- Produces:
  - `public struct FlockProfile: Codable, Equatable, Sendable, Identifiable { public static let defaultID = "default"; public let id: String; public var name: String; public var socketPath: String?; public var knownSockets: [String]; public init(id:name:socketPath:knownSockets:) }`. `socketPath` nil means herdr's default socket. `knownSockets` holds normalized paths, each once, in first-use order, the default socket included once used.
  - `public enum ProfileSuites`:
    - `static func preferencesSuiteName(bundleID: String, profileID: String) -> String?` (nil for `default`)
    - `static func serverSuiteName(bundleID: String, profileID: String, socketPath: String, defaultSocketPath: String) -> String?` (nil only for `default` on the default socket; both paths arrive normalized)
    - `static func overrideSuiteName(bundleID: String) -> String` (`<bundle id>.override`)
    - `static func socketKey(_ normalizedSocketPath: String) -> String` (first 12 lowercase hex chars of SHA-256 of the UTF-8 path)
    - `static func allSuiteNames(for profile: FlockProfile, bundleID: String, defaultSocketPath: String) -> [String]` (its preferences suite, if any, then one server suite per `knownSockets` entry that has one)
  - `@MainActor @Observable public final class ProfileStore`:
    - `public static let defaultsKey = "flock.profiles"`
    - `public init(userDefaults: UserDefaults = .standard, bundleID: String, defaultSocketPath: String, home: String = NSHomeDirectory(), removeSuite: @escaping (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) })`
    - `public private(set) var profiles: [FlockProfile]`, `public private(set) var currentID: String`, `public var current: FlockProfile { get }`
    - `public func socketPath(of profile: FlockProfile) -> String` (`profile.socketPath ?? defaultSocketPath`)
    - `public func create(name: String, socketPath: String?) -> FlockProfile?` (nil for a blank name; id is a new lowercase UUID string; `knownSockets` is `[normalized socket]`)
    - `public func rename(_ id: String, to name: String)` (blank ignored)
    - `public func setSocket(_ socketPath: String?, for id: String)` (stores the normalized path, or nil for the default socket; appends it to `knownSockets` if new)
    - `public func select(_ id: String)`
    - `public func delete(_ id: String) -> Bool` (false for `default` and for `currentID`)

Stored on `userDefaults` as one JSON value `{"profiles":[...],"currentID":"..."}`. With nothing stored, `profiles` is one `FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: [defaultSocketPath])`, `currentID` is `default`, and nothing is written until a change.

- [ ] **Step 1: Write the failing tests**

Fixtures in both classes: `home = "/Users/someone/.config/herdr/herdr.sock"`, `acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"`, home directory `/Users/someone`.

`ProfileSuitesTests`:

```swift
func testDefaultOnTheDefaultSocketUsesStandard() {
    XCTAssertNil(ProfileSuites.preferencesSuiteName(bundleID: "b", profileID: "default"))
    XCTAssertNil(ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: home, defaultSocketPath: home))
}
func testDefaultOnAnotherServerGetsItsOwnServerSuite() {
    XCTAssertEqual(
        ProfileSuites.serverSuiteName(bundleID: "b", profileID: "default", socketPath: acme, defaultSocketPath: home),
        "b.profile.default.server.\(ProfileSuites.socketKey(acme))"
    )
}
func testAnotherProfileGetsBothSuites() {
    XCTAssertEqual(ProfileSuites.preferencesSuiteName(bundleID: "b", profileID: "p1"), "b.profile.p1")
    XCTAssertEqual(
        ProfileSuites.serverSuiteName(bundleID: "b", profileID: "p1", socketPath: home, defaultSocketPath: home),
        "b.profile.p1.server.\(ProfileSuites.socketKey(home))"
    )
}
func testOverrideSuite() {
    XCTAssertEqual(ProfileSuites.overrideSuiteName(bundleID: "b"), "b.override")
}
func testSocketKeyIgnoresSpelling() {
    let spelled = HerdrServerAddress.normalize("~/.config/herdr/sessions/acme/./herdr.sock", home: "/Users/someone")
    XCTAssertEqual(ProfileSuites.socketKey(acme).count, 12)
    XCTAssertEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(spelled))
    XCTAssertNotEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(home))
}
```

`ProfileStoreTests` (each test uses `UserDefaults(suiteName: "profile-store-\(UUID())")!`, `bundleID: "b"`, `defaultSocketPath: home`, `home: "/Users/someone"`, and a `removeSuite` closure that records names):

- `testNothingStoredIsOneDefaultProfile`: `profiles == [FlockProfile(id: "default", name: "Default", socketPath: nil, knownSockets: [home])]`, `currentID == "default"`, and `userDefaults.object(forKey: ProfileStore.defaultsKey)` is nil.
- `testCreateRejectsABlankName`: `create(name: "  ", socketPath: nil)` is nil; `create(name: " Demo ", socketPath: "~/.config/herdr/sessions/acme/herdr.sock")` has name `Demo`, `socketPath == acme`, `knownSockets == [acme]`.
- `testChangesPersistAcrossInstances`: create, rename, `setSocket`, `select`; a second `ProfileStore` on the same defaults reads the same `profiles` and `currentID`.
- `testSetSocketRecordsEachServerOnce`: on Default, `setSocket(acme, for: "default")`, `setSocket(nil, for: "default")`, `setSocket(acme, for: "default")` leaves `current.knownSockets == [home, acme]` and `current.socketPath == acme`.
- `testDeleteRemovesEverySuiteAndNothingElse`: a profile created on `acme`, then `setSocket(nil, ...)`; `delete` returns true and `removeSuite` saw exactly `["b.profile.<id>", "b.profile.<id>.server.<key acme>", "b.profile.<id>.server.<key home>"]`; the stored list no longer has it.
- `testDefaultAndCurrentCannotBeDeleted`: both return false and `removeSuite` saw nothing.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/ProfileSuitesTests -only-testing:FlockCoreTests/ProfileStoreTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ProfileStore' in scope`.

- [ ] **Step 3: Implement the three files to the interfaces above**

- [ ] **Step 4: Run the tests again**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Profiles Tests/FlockCoreTests/ProfileSuitesTests.swift Tests/FlockCoreTests/ProfileStoreTests.swift
Scripts/checks.sh
git commit -m "profiles: the profile list and its UserDefaults suites"
```

---

### Task 3: A session that can be torn down

Today nothing in the per-socket graph is ever stopped, because the process ending did it. This task adds the stops.

**Files:**
- Modify: `Sources/FlockCore/Herdr/PaneScrollSubscriber.swift` (protocol + `HerdrPaneScrollSubscriber`)
- Modify: `Sources/FlockCore/Herdr/PaneAgentStatusSubscriber.swift` (protocol + `HerdrPaneAgentStatusSubscriber`)
- Modify: `Sources/FlockCore/Rt/RtCoordinator.swift`
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (init around :258-294; `attachPane` at :1214; new `shutdown()`)
- Modify: `Sources/Flock/Ghostty/HerdrHoldCoordinator.swift`
- Modify: `Sources/Flock/Chat/ChatStore.swift`
- Test: `Tests/FlockCoreTests/SessionViewModelTests.swift` (its private fakes live here)
- Modify: `Tests/FlockCoreTests/SessionViewModelTopBarTests.swift` (its private `FakePaneAgentStatusSubscriber` at :43 needs `unsubscribeAll()`)
- Test: `Tests/FlockChromeRender/HerdrHoldCoordinatorTests.swift`, `Tests/FlockChromeRender/ChatStoreTests.swift`

**Interfaces:**
- Produces:
  - `PaneScrollSubscribing.unsubscribeAll()` and `PaneAgentStatusSubscribing.unsubscribeAll()` (protocol requirements; the real ones cancel every feed)
  - `RtCoordinator.shutdown()` (cancels `watches`, `shutdowns`, `pendingWork`; touches no rt item and no pane)
  - `SessionViewModel.init(..., rtLinkedPaneDefaults: UserDefaults? = nil, ...)`: when non-nil and `rt` is nil, builds `RtCoordinator(client:linkedPanes: RtLinkedPanes(defaults:), notice:)`
  - `SessionViewModel.shutdown() async`: marks the view model shut down; waits on in-flight `paneWork`; detaches every surface in `ghosttySurfaces` (parked included); cancels `promptWatches`, `navigationWatches` and `backgroundWorkTimer`; `unsubscribeAll()` on both subscribers; `rt.shutdown()`; `flushPaneTitles()`. Idempotent.
  - `attachPane(_:)` returns nil once shut down, without calling the factory.
  - `HerdrHoldCoordinator.invalidate()` (removes its observers, invalidates `releaseTimer`)
  - `ChatStore.stop()` (cancels `probeTask` and `peekTask`)

- [ ] **Step 1: Write the failing tests**

In `SessionViewModelTests.swift`, give `FakePaneScrollSubscriber` (:333) and `FakePaneAgentStatusSubscriber` (:344) a `private(set) var unsubscribedAll = false` set by `unsubscribeAll()`; give the one in `SessionViewModelTopBarTests.swift` an empty `unsubscribeAll()`. Then:

```swift
func testShutdownDetachesEverySurfaceAndDropsEveryFeed() async {
    let factory = FakeGhosttyPaneFactory()
    let scroll = FakePaneScrollSubscriber()
    let status = FakePaneAgentStatusSubscriber()
    let viewModel = SessionViewModel(
        client: RecordingCommandClient(), ghosttyFactory: factory,
        paneScrollSubscriber: scroll, paneAgentStatusSubscriber: status
    )
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p1"))
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p2"))
    await viewModel.shutdown()
    XCTAssertEqual(factory.surfaces.values.map(\.detachCallCount), [1, 1])
    XCTAssertTrue(scroll.unsubscribedAll)
    XCTAssertTrue(status.unsubscribedAll)
}

func testShutdownDetachesParkedSurfacesAndEndsRtWatches() async {
    let factory = FakeGhosttyPaneFactory()
    let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
    let parked = PaneID(rawValue: "w1:p1")
    _ = await viewModel.attachPane(parked)
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p2"))
    await viewModel.detachPane(parked)   // parks: the fake surface is off screen
    XCTAssertEqual(factory.surfaces[parked]?.parkCallCount, 1)
    viewModel.rt.startWatch("tok1")
    await viewModel.shutdown()
    XCTAssertEqual(factory.surfaces.values.map(\.detachCallCount), [1, 1])
    XCTAssertTrue(viewModel.rt.watches.isEmpty)
}

func testShutdownTwiceDetachesOnce() async {
    let factory = FakeGhosttyPaneFactory()
    let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p1"))
    await viewModel.shutdown()
    await viewModel.shutdown()
    XCTAssertEqual(factory.surfaces.values.map(\.detachCallCount), [1])
}

func testNoAttachAfterShutdown() async {
    let factory = FakeGhosttyPaneFactory()
    let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
    await viewModel.shutdown()
    let surface = await viewModel.attachPane(PaneID(rawValue: "w1:p1"))
    XCTAssertNil(surface)
    XCTAssertEqual(factory.makeSurfaceCalls, [])
}

func testRtLinkedPanesUseTheDefaultsTheyAreGiven() {
    let defaults = UserDefaults(suiteName: "rt-linked-\(UUID())")!
    let viewModel = SessionViewModel(client: RecordingCommandClient(), rtLinkedPaneDefaults: defaults)
    viewModel.rt.linkedPanes.record(PaneID(rawValue: "w1:p9"), for: "tok-\(UUID())")
    XCTAssertNotNil(defaults.object(forKey: RtLinkedPanes.key))
}
```

(`RtLinkedPanes.key` is the existing internal `static let key = "flock.rt.linkedPanes"`, reachable through `@testable import`.)

`HerdrHoldCoordinatorTests.testInvalidateStopsReactingToActivation`: build it with the `release:take:notificationCenter:isOnScreen:` init and a private `NotificationCenter()`, call `invalidate()`, post `NSApplication.didBecomeActiveNotification` on that center, spin the main queue once; `take` was never called.
`ChatStoreTests.testStopCancelsTheProbe`: `stop()` then `XCTAssertTrue(store.probeTask.isCancelled)`.

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/SessionViewModelTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `value of type 'SessionViewModel' has no member 'shutdown'`.

- [ ] **Step 3: Implement the interfaces above**

- [ ] **Step 4: Run the tests again, plus the top-bar suite and the two Flock-side ones**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/SessionViewModelTests -only-testing:FlockCoreTests/SessionViewModelTopBarTests -skipPackagePluginValidation -derivedDataPath build/dd`, then `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/HerdrHoldCoordinatorTests -only-testing:FlockChromeRender/ChatStoreTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: both `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests
Scripts/checks.sh
git commit -m "session teardown: detach every surface, drop every feed, stop rt watches"
```

---

### Task 4: The switch, as an orchestration with no AppKit

**Files:**
- Create: `Sources/FlockCore/Profiles/ProfileSessionController.swift`
- Test: `Tests/FlockCoreTests/ProfileSessionControllerTests.swift`

**Interfaces:**
- Consumes: `ProfileStore`, `ProfileSuites`, `FlockProfile` (Task 2); `HerdrServerAddress` (Task 1).
- Produces:

```swift
@MainActor public protocol ProfileSession: AnyObject {
    func start() async
    func shutdown() async
}

public struct ProfileSessionContext {
    public let profile: FlockProfile
    public let socketPath: String
    public let preferences: UserDefaults
    public let idState: UserDefaults
    public init(profile: FlockProfile, socketPath: String, preferences: UserDefaults, idState: UserDefaults)
}

public struct ProfileSessionEnvironment<Session: ProfileSession> {
    public var bundleID: String
    public var defaultSocketPath: String
    public var home: String
    /// `HERDR_SOCKET_PATH` from flock's own environment, when set.
    public var socketOverride: String?
    /// A nil suite name means `UserDefaults.standard`.
    public var defaults: @MainActor (_ suiteName: String?) -> UserDefaults
    /// false cancels the switch before anything is torn down or saved.
    public var confirmAttach: @MainActor (_ socketPath: String, _ stayLabel: String) async -> Bool
    public var register: @MainActor (_ socketPath: String) -> Void
    public var setChildSocket: (_ socketPath: String) -> Void
    public var make: @MainActor (ProfileSessionContext) -> Session
    public init(bundleID:defaultSocketPath:home:socketOverride:defaults:confirmAttach:register:setChildSocket:make:)
}

@MainActor @Observable public final class ProfileSessionController<Session: ProfileSession> {
    public let profiles: ProfileStore
    public private(set) var session: Session
    /// Bumped on every completed switch; the window keys its content on it.
    public private(set) var generation: Int
    public var isLocked: Bool { get }          // socketOverride != nil
    public var socketPath: String { get }      // the current session's
    public init(profiles: ProfileStore, environment: ProfileSessionEnvironment<Session>)
    @discardableResult public func switchTo(profileID: String) async -> Bool
    @discardableResult public func changeServer(to socketPath: String?) async -> Bool
}
```

Rules:
- **Contexts.** Preferences come from `ProfileSuites.preferencesSuiteName`. id state comes from `ProfileSuites.serverSuiteName` for (profile, socket), or from `overrideSuiteName` when `socketOverride` is set. Socket paths are normalized with `HerdrServerAddress.normalize`.
- **`init`.** Calls `setChildSocket` then `make` for the current profile on its socket (or the override). It does not call `start`, `confirmAttach` or `register`; `FlockApp`'s launch does those (Task 6).
- **A switch, in order.**
  1. Refuse (return false) when locked, or when the target equals the current (profile, socket).
  2. `confirmAttach(newSocket, label)`, where `label` is the current profile's name for `switchTo` and `HerdrServerAddress(socketPath: current socket).label` for `changeServer`. Return false on no.
  3. `await session.shutdown()`.
  4. Save: `select` or `setSocket`.
  5. `setChildSocket(new)`, then `make(context)`, then `register(new)`.
  6. `generation += 1`, then `await session.start()`.
- **Concurrency.** A request arriving while one runs waits for it: chain each request's `Task` on the previous one; don't drop it.

- [ ] **Step 1: Write the failing tests**

Fixtures: `home = "/Users/someone/.config/herdr/herdr.sock"`, `acme = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"`, home directory `/Users/someone`, `bundleID: "b"`. A `FakeSession: ProfileSession` appends `"start <socket>"` / `"shutdown <socket>"` to a shared `[String]` log. The environment's closures append `"confirm <socket> <label>"`, `"register <socket>"`, `"child <socket>"`, `"make <profile id> <socket>"`, and `defaults` appends `"suite <name or standard>"` and returns `UserDefaults(suiteName: "psc-\(runID)-\(name ?? "standard")")!`. The `ProfileStore` uses its own per-test suite. Profile `p1` is created on `acme` before the controller is built.

- `testLaunchBuildsTheCurrentProfileOnItsSocketAndStartsNothing`: log is `["child <home>", "suite standard", "suite standard", "make default <home>"]` (the two suite lines in either order); `generation == 0`.
- `testASwitchRunsInOrder`: after launch, `switchTo(profileID: "p1")` appends `["confirm <acme> Default", "shutdown <home>", "child <acme>", "suite b.profile.p1", "suite b.profile.p1.server.<key acme>", "make p1 <acme>", "register <acme>", "start <acme>"]`; `generation == 1`; the store's `currentID == "p1"`.
- `testARefusedSwitchSavesNothing`: `confirmAttach` returns false; result false; nothing after the `confirm` line; `currentID` and every profile's `socketPath` and `knownSockets` unchanged; `generation == 0`.
- `testChangingServerKeepsTheProfileAndRemembersBothServers`: `changeServer(to: acme)` on Default logs `"confirm <acme> default"` (the server label), `"suite b.profile.default.server.<key acme>"`, `"make default <acme>"`; `current.knownSockets == [home, acme]`; `current.socketPath == acme`.
- `testOverrideUsesTheOverrideSuiteAndLocks`: `socketOverride: "/tmp/acme/x.sock"`; launch logs `"suite b.override"` and `"make default /tmp/acme/x.sock"`; `isLocked`; both switch calls return false and log nothing more; the store's profiles are unchanged.
- `testSwitchingToWhereYouAreDoesNothing`: `switchTo(profileID: "default")` from Default returns false; nothing logged after launch.
- `testASwitchRequestedMidSwitchWaitsItsTurn`: `FakeSession.shutdown` suspends on a `CheckedContinuation` the test resumes. Create `p2` on the default socket. Fire `switchTo("p1")` and `switchTo("p2")` as two `Task`s without awaiting the first; resume. The log shows p1's full sequence, ending with `"start <acme>"`, before p2's `confirm`. Exactly one `start` follows each `make`.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/ProfileSessionControllerTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ProfileSessionController' in scope`.

- [ ] **Step 3: Implement `ProfileSessionController.swift` to the interface and rules above**

- [ ] **Step 4: Run the tests again**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Profiles/ProfileSessionController.swift Tests/FlockCoreTests/ProfileSessionControllerTests.swift
Scripts/checks.sh
git commit -m "profiles: switch sessions in place, guard first, one at a time"
```

---

### Task 5: Child tools follow the session; servers start with their own socket; the guard can cancel a switch

**Files:**
- Modify: `Sources/Flock/Environment/ToolPath.swift`
- Modify: `Sources/Flock/Herdr/HerdrServerLauncher.swift`
- Create: `Sources/Flock/Herdr/HerdrSessionLister.swift`
- Modify: `Sources/Flock/Environment/FlockClientGuard.swift`
- Test: `Tests/FlockChromeRender/NoHerdrScreenTests.swift` (the launcher environment tests live here), `Tests/FlockChromeRender/ToolPathEnvironmentTests.swift` (new)

**Interfaces:**
- Consumes: `HerdrSessionList.parse`, `HerdrServerAddress` (Task 1).
- Produces:
  - `ToolPath.setHerdrSocket(_ socketPath: String)`, stored behind an `OSAllocatedUnfairLock<String?>` because `childEnvironment()` runs off the main actor.
  - `ToolPath.childEnvironment(base: [String: String], path: String, herdrSocket: String?) -> [String: String]`: the pure part. Sets `PATH` and `RT_BATCH=1`, plus `HERDR_SOCKET_PATH` when `herdrSocket` is non-nil. `childEnvironment()` calls it with the process environment, `resolved` and the stored socket.
  - `enum HerdrServerLauncher.Target: Equatable { case defaultServer; case named(String); case overrideSocket(String) }`
  - `HerdrServerLauncher.start(_ target: Target) -> Result<Void, Failure>`:
    - argv is `[binary, "--session", name, "server"]` for `.named`, else `[binary, "server"]`.
    - For `.named`, it first creates `~/.config/herdr/sessions/<name>/` with intermediate directories.
  - `HerdrServerLauncher.environment(from: [String: String], target: Target) -> [String: String]`:
    - Strips `RT_BATCH` and sets `HERDR_MACOS_SERVER_CONTEXT=user`, as today.
    - Removes `HERDR_SOCKET_PATH` for `.defaultServer` and `.named`.
    - Sets it to the path for `.overrideSocket`.
  - `enum HerdrSessionLister { static func list() async -> [HerdrSessionEntry]? }`: `herdr session list --json` through `ToolRunner`, with a 5 s deadline and the child environment.
  - `FlockClientGuard.register(socketPath: String)`: writes this pid's record. It installs the will-terminate unregister once per process, not once per call.
  - `FlockClientGuard.confirmAttach(socketPath: String, defaultSocketPath: String, stayLabel: String) async -> Bool`:
    - Runs the same conflict check as launch, with the buttons "Quit <other>", "Stay on <stayLabel>" and "Keep Both".
    - "Stay on" returns false.
    - "Quit <other>" waits as today, then returns true.
    - "Keep Both" returns true.
  - `FlockClientGuard.settle(...)` keeps its launch behaviour, now built on `register` and the shared conflict check.

- [ ] **Step 1: Write the failing tests**

Replace `testTheServerStartsWithoutRtsBatchFlag` and add:

```swift
func testTheServerStartsWithoutRtsBatchFlag() {
    let environment = HerdrServerLauncher.environment(from: ["RT_BATCH": "1", "PATH": "/usr/bin"], target: .defaultServer)
    XCTAssertNil(environment["RT_BATCH"])
    XCTAssertEqual(environment["PATH"], "/usr/bin")
}
func testDefaultAndNamedServersStartWithoutTheSessionsSocket() {
    for target: HerdrServerLauncher.Target in [.defaultServer, .named("acme")] {
        let environment = HerdrServerLauncher.environment(from: ["HERDR_SOCKET_PATH": "/tmp/h.sock"], target: target)
        XCTAssertNil(environment["HERDR_SOCKET_PATH"], "\(target)")
    }
}
func testAnOverrideServerStartsOnItsSocket() {
    let environment = HerdrServerLauncher.environment(from: [:], target: .overrideSocket("/tmp/acme/x.sock"))
    XCTAssertEqual(environment["HERDR_SOCKET_PATH"], "/tmp/acme/x.sock")
}
```

`testTheServerAsksHerdrForThePerUserServiceContext` passes `target: .defaultServer`.

`ToolPathEnvironmentTests`:
- `testChildToolsAreToldTheSessionsSocket`: `herdrSocket: "/Users/someone/.config/herdr/sessions/acme/herdr.sock"` sets `HERDR_SOCKET_PATH` to it, `RT_BATCH == "1"`, and `PATH` to the given path.
- `testNoSocketLeavesTheInheritedOne`: `herdrSocket: nil` keeps a base `HERDR_SOCKET_PATH`.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/NoHerdrScreenTests -only-testing:FlockChromeRender/ToolPathEnvironmentTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails on the missing `target:` parameter.

- [ ] **Step 3: Implement the interfaces above**

`FlockApp.startHerdr` still calls the old `start()`. Keep a `static func start() -> Result<Void, Failure> { start(.defaultServer) }` until Task 6 replaces the call. The guard's alert is AppKit and stays untested; the conflict decision stays in `FlockClientConflict.others`.

- [ ] **Step 4: Run the tests again**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Herdr/HerdrSessionLister.swift Tests/FlockChromeRender/ToolPathEnvironmentTests.swift
Scripts/checks.sh
git commit -m "child tools follow the session's socket; servers start on their own; guard can cancel a switch"
```

---

### Task 6: `FlockSession`, and `FlockApp` built on it

The largest task: a move, not new behaviour. After it, flock with no profile list stored must behave exactly as before.

**Files:**
- Create: `Sources/Flock/Environment/FlockSession.swift`
- Modify: `Sources/Flock/FlockApp.swift`
- Test: `Tests/FlockChromeRender/FlockSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 5. From Task 4: `ProfileSession`, `ProfileSessionContext`, `ProfileSessionEnvironment`, `ProfileSessionController`. From Task 3: `SessionViewModel.shutdown()`, `rtLinkedPaneDefaults:`, `HerdrHoldCoordinator.invalidate()`, `ChatStore.stop()`. From Task 5: `ToolPath.setHerdrSocket`, `FlockClientGuard.register/confirmAttach/settle`, `HerdrServerLauncher.start(_:)`.
- Produces:
  - `@MainActor @Observable final class FlockSession: ProfileSession`
  - `init(context: ProfileSessionContext, ghosttyHost: GhosttyHost?, board: BoardStore, herdProgress: HerdProgressStore, resnapshotInterval: Duration?, home: String = NSHomeDirectory())`
  - Stored: everything `FlockApp.init` builds per session today, each from the suite named in the table below. That is `herdrStore`, `viewModel`, `undoJournal`, `toastCenter`, `chatStore`, `rearrangeMode`, `dragCoordinator`, `dividerDragCoordinator`, `herdrHoldCoordinator`, `commandPalette`, `workspaceSwitcher`, `tabSwitcher`, the ghostty control surface factory and both pane subscribers, plus every preference store.
  - `let socketPath: String`, `let address: HerdrServerAddress`, `let profile: FlockProfile`
  - `var isStartingHerdr = false`, `var herdrStartFailure: String?` (moved off `FlockApp`, so a failure on one server never shows on the next)
  - `start()`: `await herdrStore.start()`
  - `shutdown()`, in order: `herdrHoldCoordinator.invalidate()`, `herdrStore.stop()`, `await viewModel.shutdown()`, `chatStore.stop()`, then clear `toastCenter`'s toasts.

Which `UserDefaults` each store gets:

| `context.preferences` | `context.idState` | app-level, `.standard` |
|---|---|---|
| `ThemeStore`, `TerminalTextSizeStore`, `RtModalSizeStore`, `RtModalTextSizeStore`, `TopBarLabelStore`, `OptionAsAltStore`, `ScrollSpeedStore`, `LinkTrustStore`, `NotificationLifetimeStore`, `OneTitleStore`, `AgentCloseWarningStore`, `StartingFolderStore`, `RearrangeAfterMoveStore`, `MissionBottomLineStore`, `OverviewReturnStore`, `OverviewInclusionStore`, `AllWorkspacesModeStore`, `RailWidthStore`, `SectionCollapseStore`, `PaletteRecentsStore` | `WorkspaceIdentityStore`, `TopBarOverlaySizeStore` (keyed by pin; pins are id state), `AttentionToastArchive`, `PaneLastChangeArchive`, `WorkspaceSwitcher`, `TabSwitcher`, and the view model's `rightClickDefaults`, `completedTabDefaults`, `paneTitleDefaults`, `pinnedWorkspaceDefaults`, `rtLinkedPaneDefaults` | `BoardStore`, `HerdrMousePatchStore`, `DevRebuild`, `MainWindowFrameKeeper`, `ApplePersistenceIgnoreState` |

These objects stay on `FlockApp`, built once per launch:
- `GhosttyHost`, one libghostty app. Its `onClipboardWrite` is re-pointed at the new session's `toastCenter` on every switch: observe `controller.generation`.
- `ProfileStore` and `ProfileSessionController<FlockSession>`.
- `BoardStore`, `HerdProgressStore`, `CswapStore` and `HerdrToolStore`.
- `HerdrMousePatchStore`, and `HerdrUpdateStore`, whose `installedVersion` reads `controller.session.viewModel.model?.herdrVersion`.
- `SettingsTabSelection`, `CommandLineToolStore` and `DevBuildWatcher`.
- `DevRebuild`. Its `notice` calls `controller.session.toastCenter.show`, reaching the current session through the controller rather than capturing the first one.
- The updater.

`FlockApp` changes:
- **`init`.**
  1. Build `ProfileStore(bundleID: Bundle.main.bundleIdentifier ?? "dev.mattstack.Flock", defaultSocketPath:)`.
  2. Build the controller. Its environment uses `FlockClientGuard.confirmAttach` (with `defaultSocketPath`), `FlockClientGuard.register` and `ToolPath.setHerdrSocket`, and a `make` that builds `FlockSession`. The controller's own init sets the child socket before any session task can run (Task 4).
  3. `socketOverride` is today's `HERDR_SOCKET_PATH` read. `defaultSocketPath` comes from `HerdrServerAddress.defaultServer.socketPath(home: NSHomeDirectory())`, and the status line's label from `controller.session.address.label`.
- **Stores.** Each former `@State` session object becomes a computed property reading `controller.session`, so `body` and the commands keep their names.
- **Window identity.** The window's content gets `.id(controller.generation)`. The `.task`, `.onReceive` and `.onChange` modifiers sit outside it, so they run once per launch. The launch `.task` calls `FlockClientGuard.settle`, then `await controller.session.start()`.
- **Terminate.** `FlockAppDelegate.onTerminate` gets one closure that flushes `controller.session.viewModel`'s pane titles.
- **`startHerdr`.** It now calls `HerdrServerLauncher.start(target)`, where `target` is `.overrideSocket(path)` under an override, `.named(n)` for `.named(n)`, and `.defaultServer` for the default. It writes the session's `isStartingHerdr` and `herdrStartFailure`.
- **Resnapshot.** `FLOCK_RESNAPSHOT_SECONDS` still applies, through `resnapshotInterval`.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class FlockSessionTests: XCTestCase {
    func testPreferencesAndIdStateLandInTheirOwnSuites() {
        let preferences = UserDefaults(suiteName: "fs-prefs-\(UUID())")!
        let idState = UserDefaults(suiteName: "fs-ids-\(UUID())")!
        preferences.set("one-light", forKey: ThemeStore.defaultsKey)
        let socket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"
        let session = FlockSession(
            context: ProfileSessionContext(
                profile: FlockProfile(id: "p1", name: "Acme", socketPath: socket, knownSockets: [socket]),
                socketPath: socket, preferences: preferences, idState: idState
            ),
            ghosttyHost: nil,
            board: BoardStore(sources: BoardSources(readSetting: { nil }, fetchLogo: { nil }), userDefaults: idState),
            herdProgress: HerdProgressStore(sources: HerdProgressSources(listHerds: { nil }, readStatus: { _ in nil })),
            resnapshotInterval: nil, home: "/Users/someone"
        )
        XCTAssertEqual(session.address, .named("acme"))
        XCTAssertEqual(session.themeStore.active.id, "one-light")
        session.workspaceIdentityStore.setOverride(WorkspaceSymbols.all[0].name, for: "w1")
        XCTAssertNotNil(idState.data(forKey: WorkspaceIdentityStore.defaultsKey))
        XCTAssertNil(preferences.data(forKey: WorkspaceIdentityStore.defaultsKey))
    }
}
```

Teardown itself is covered by Task 3 and the switch order by Task 4; this test pins only the wiring.

- [ ] **Step 2: Regenerate and run to see it fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/FlockSessionTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'FlockSession' in scope`.

- [ ] **Step 3: Create `FlockSession.swift` and move construction out of `FlockApp.init`**

- [ ] **Step 4: Run the new test and the suites that render real views**

Run the Step 2 command, then `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ChromeRenderTests -only-testing:FlockChromeRender/NoHerdrScreenTests -skipPackagePluginValidation -derivedDataPath build/dd`, then `xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd` (FlockApp.swift is outside the render target).
Expected: `** TEST SUCCEEDED **` twice and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Check nothing changed for an existing install**

Run: `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev` and ask Matt to click "New build · Restart" in Flock Dev.
Expected: Flock Dev opens on its usual server with its pins, symbols, theme and text size as before, and `defaults read dev.mattstack.Flock.dev flock.profiles` says the key does not exist.

- [ ] **Step 6: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Environment/FlockSession.swift Tests/FlockChromeRender/FlockSessionTests.swift
Scripts/checks.sh
git commit -m "FlockSession: everything per profile and server in one object FlockApp swaps"
```

---

### Task 7: The not-running screen names the server it waits for

**Files:**
- Modify: `Sources/Flock/Views/NoHerdrScreen.swift`
- Modify: `Sources/Flock/FlockApp.swift` (`notRunningCopy`, the not-running branch of `body`)
- Modify: `Sources/FlockCore/Store/HerdrStore.swift:639-643` (`defaultBackoff`)
- Test: `Tests/FlockChromeRender/NoHerdrScreenTests.swift`, `Tests/FlockCoreTests/HerdrStoreBackoffTests.swift` (new)

**Interfaces:**
- Consumes: `HerdrServerAddress` (Task 1); `FlockSession.address`, `isStartingHerdr`, `herdrStartFailure`, `controller.isLocked` (Task 6).
- Produces:
  - `static func notRunning(for address: HerdrServerAddress) -> NoHerdrScreen.Copy`. `.defaultServer` returns today's `notRunning` copy unchanged.
  - `static func startTitle(for address: HerdrServerAddress, isOverride: Bool, isStarting: Bool) -> String?`: nil means no button. A `.custom` address gets nil unless `isOverride` is true (today's override keeps its Start). Otherwise the title is today's "Start herdr", or "Starting herdr…" while `isStarting` is true.
  - `FlockApp` builds the not-running branch's `primaryAction` from `startTitle`, so no button decision lives in `FlockApp`.

| address | headline | body | hint |
|---|---|---|---|
| `.named(n)` | `The herdr server “n” isn't running.` | `flock is checking for it and will attach as soon as it starts.` | `Start it here, or run herdr --session n in a terminal.` |
| `.custom(p)` | `Nothing is answering at p.` | `flock is checking and will attach as soon as a herdr server is listening there.` | `Start that server however it is normally started.` |

- `defaultBackoff` caps at 2,000 ms instead of 15,000, so a server started outside flock is picked up within about two seconds.

- [ ] **Step 1: Write the failing tests**

- `testNamedAndCustomCopy`: asserts the table above for `.named("acme")` and `.custom("/tmp/acme/x.sock")`.
- `testDefaultCopyIsUnchanged`: `notRunning(for: .defaultServer) == NoHerdrScreen.notRunning`.
- `testOnlyAPickedCustomPathHasNoStartButton`: `startTitle(for: .custom(p), isOverride: false, isStarting: false) == nil`; `startTitle(for: .custom(p), isOverride: true, isStarting: false) == "Start herdr"`; `startTitle(for: .named("acme"), isOverride: false, isStarting: true) == "Starting herdr…"`.
- `HerdrStoreBackoffTests.testBackoffNeverWaitsMoreThanTwoSeconds`: `HerdrStore.defaultBackoff(attempt: 1) == .milliseconds(500)` and `defaultBackoff(attempt: 50) == .seconds(2)`.

Extend `testRendersOverTheThemesChromeWithNoButtonByDefault`'s theme loop (dark `tokyoNight` and `one-light`) to also write `no-herdr-named-<theme id>.png` and `no-herdr-custom-<theme id>.png` to `FLOCK_CHROME_RENDER_DIR`.

- [ ] **Step 2: Regenerate and run them to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/NoHerdrScreenTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `type 'NoHerdrScreen' has no member 'notRunning(for:)'`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run the tests, then render and look**

Run the Step 2 command, then `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrStoreBackoffTests -skipPackagePluginValidation -derivedDataPath build/dd`. Then:

```bash
RENDER=$PWD/build/renders/no-herdr; mkdir -p $RENDER
TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=$RENDER xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/NoHerdrScreenTests -skipPackagePluginValidation -derivedDataPath build/dd
open $RENDER/no-herdr-*.png
```

Expected: green, with `HerdrStoreBackoffTests` listed as executed. In both themes the session name or path reads in full with no clipping.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Tests/FlockCoreTests/HerdrStoreBackoffTests.swift
Scripts/checks.sh
git commit -m "not-running screen names the server it waits for; retry every two seconds at most"
```

---

### Task 8: Settings > herdr > Server

**Files:**
- Create: `Sources/Flock/Views/Settings/ServerPicker.swift` (model)
- Create: `Sources/Flock/Views/Settings/ServerSettingsSection.swift` (view)
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift` (herdr tab; init gains `serverPicker: ServerPicker? = nil`)
- Modify: `Sources/Flock/FlockApp.swift` (builds the picker, passes it)
- Test: `Tests/FlockChromeRender/ServerPickerTests.swift`, `Tests/FlockChromeRender/ChromeRenderTests.swift` (settings render cases, around :2771-2880)

**Interfaces:**
- Consumes: `HerdrSessionLister.list`, `HerdrServerLauncher.start(_:)` (Task 5); `ProfileSessionController.changeServer(to:)`, `isLocked`, `socketPath` (Task 4); `HerdrServerAddress` (Task 1).
- Produces: `@MainActor @Observable final class ServerPicker`:
  - `init(list: @escaping () async -> [HerdrSessionEntry]?, start: @escaping (String) -> Result<Void, HerdrServerLauncher.Failure>, choose: @escaping (String?) async -> Bool, currentSocket: @escaping () -> String, isLocked: Bool, home: String)`. `start` takes a session name; FlockApp passes `{ HerdrServerLauncher.start(.named($0)) }`.
  - `private(set) var entries: [HerdrSessionEntry]`, `private(set) var failure: String?`
  - `func refresh() async`: called when the menu opens and when the section appears.
  - `func choose(_ entry: HerdrSessionEntry) async`: `choose(nil)` for the default entry, else `choose` with its socket.
  - `func startServer(name: String) async -> String?`. It starts a server and returns its socket without choosing it. An invalid name (per `HerdrServerAddress.isValidSessionName`) sets `failure` and returns nil without starting; a start failure also sets `failure` and returns nil. Task 9 uses it for new profiles.
  - `func startNew(name: String) async`: `startServer`, then `choose` the returned socket.
  - `func chooseCustom(path: String) async`. Empty input is ignored. Otherwise the path goes through `HerdrServerAddress(socketPath:home:)`: `.defaultServer` chooses nil; anything else chooses its `socketPath(home:)`, so the session is handed an expanded, normalized path.
  - `failure` copy: `"<name>" can't be a server name. Use letters, digits, ".", "_" or "-".` for an invalid name; for a start failure, the same messages `FlockApp.startHerdr` shows today.

The section has one row, "Server", with a menu:
- Each entry shows its `name` plus a trailing "running" or "stopped" note, with a check on the current one.
- A divider follows the entries.
- "New Server…" shows a name field and a Start button inline under the row.
- "Custom Socket Path…" shows a path field and a Use button inline.
- When locked, the menu is disabled and the row's note reads `Set by HERDR_SOCKET_PATH: <path>`.

- [ ] **Step 1: Write the failing tests**

`ServerPickerTests`, with closures that record calls and `home: "/Users/someone"`:
- `testChoosingDefaultPassesNil` and `testChoosingANamedEntryPassesItsSocket`.
- `testStartNewStartsThenChoosesTheNewSocket`: `start` saw `"demo"`, and `choose` saw `/Users/someone/.config/herdr/sessions/demo/herdr.sock`.
- `testStartServerDoesNotChoose`: it returns that socket, and `choose` was never called.
- `testStartNewRejectsABadNameWithoutStarting`: `"a b"` and `".."` each set `failure`; `start` is never called.
- `testAStartFailureIsShownAndNothingIsChosen`.
- `testCustomPathsAreExpandedAndTheDefaultIsRecognised`: `"~/.config/herdr/herdr.sock"` calls `choose(nil)`; `"~/acme/x.sock"` calls `choose("/Users/someone/acme/x.sock")`.

Settings render: add `herdr-server-<light|dark>` and `herdr-server-locked-<light|dark>` cases to the existing settings render loop, with a `ServerPicker` over canned entries `default` (running) and `acme` (stopped).

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ServerPickerTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ServerPicker' in scope`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run, render, look**

```bash
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ServerPickerTests -skipPackagePluginValidation -derivedDataPath build/dd
RENDER=$PWD/build/renders/settings; mkdir -p $RENDER
TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=$RENDER xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ChromeRenderTests -skipPackagePluginValidation -derivedDataPath build/dd
open $RENDER/settings-herdr-server-*.png
```

Expected: green. In both appearances:
- The row sits under the update and mouse patch rows.
- The locked note is readable.
- Nothing clips at 560 wide.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Views/Settings/ServerPicker.swift Sources/Flock/Views/Settings/ServerSettingsSection.swift Tests/FlockChromeRender/ServerPickerTests.swift
Scripts/checks.sh
git commit -m "settings: choose this profile's herdr server, start a new one, or name a socket"
```

---

### Task 9: Profiles tab and the Profile menu

**Files:**
- Create: `Sources/Flock/Views/Settings/ProfilesSettingsSection.swift`
- Create: `Sources/Flock/Menus/ProfileCommands.swift`
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift`:
  - `SettingsTab.profiles`: title "Profiles", symbol `person.2`, placed after `.general`.
  - The init gains `profiles: ProfileStore? = nil`, `isLocked: Bool = false`, `switchProfile: ((String) async -> Bool)? = nil` and `changeServer: ((String?) async -> Bool)? = nil`. The defaults keep existing call sites compiling.
- Modify: `Sources/Flock/Views/Settings/SettingsTabSelection.swift` (`var opensNewProfile = false`)
- Modify: `Sources/Flock/FlockApp.swift` (`.commands` adds `ProfileCommands`; passes the new Settings parameters)
- Test: `Tests/FlockChromeRender/ProfileCommandsTests.swift`, `Tests/FlockChromeRender/ChromeRenderTests.swift` (settings render cases)

**Interfaces:**
- Consumes: `ProfileStore` (`create`, `rename`, `delete`, `setSocket`, `socketPath(of:)`) from Task 2; `ProfileSessionController.switchTo(profileID:)`, `changeServer(to:)` and `isLocked` from Task 4; `ServerPicker` (`entries`, `refresh`, `startServer(name:)`) from Task 8; `HerdrServerAddress` from Task 1; `SettingsTabSelection`.
- Produces:
  - `struct ProfileMenuRow: Equatable { let id: String; let title: String; let isCurrent: Bool }`
  - `struct ProfileCommands: Commands`, placed with `CommandGroup(after: .appSettings)`:
    - A `Menu("Profile")` with one item per row, checkmarked when current. Picking one calls `switchTo`.
    - Then a divider, "New Profile…" and "Manage Profiles…".
    - Both of the last two set `settingsTabSelection.tab = .profiles` and call `openSettings()` from a view's `@Environment(\.openSettings)`. "New Profile…" also sets `opensNewProfile = true`.
    - Every item is disabled when locked.
  - `static func rows(profiles: [FlockProfile], currentID: String) -> [ProfileMenuRow]` on `ProfileCommands`.
  - `ProfilesSettingsSection`:
    - **One row per profile**:
      - Shows the name, its server's `HerdrServerAddress.label` and "Current" on the current profile.
      - **Switch** (hidden on the current profile).
      - **Rename** (an inline field).
      - **Server menu.** It lists `ServerPicker.entries` and "Custom Socket Path…". On the current profile it calls `changeServer`; on any other it only calls `profiles.setSocket`.
      - **Delete.** Disabled for Default and for the current profile. A confirmation alert names the profile and says its herdr server keeps running.
    - **New Profile form**, below the rows, open when `opensNewProfile` is true or after its button is pressed:
      - A Name field.
      - A Server menu, whose first and preselected entry is "New server", then each listed session, then "Custom Socket Path…".
      - A server-name field shown while "New server" is chosen. It defaults to the profile name lowercased, with each character outside `[a-z0-9._-]` replaced by `-` and leading `.` or `-` trimmed, and is editable.
      - **Create and Switch**:
        1. For "New server", calls `ServerPicker.startServer(name:)` and stops on nil (its `failure` shows under the field).
        2. Calls `profiles.create(name:socketPath:)` with the chosen socket.
        3. Calls `switchProfile`.
      - If the switch is refused, the new profile stays in the list, not current.
    - When locked, the tab shows `Profiles are off while HERDR_SOCKET_PATH is set.` and nothing else.

- [ ] **Step 1: Write the failing tests**

`ProfileCommandsTests.testRowsListEveryProfileAndCheckTheCurrent`: two profiles (`default`/"Default", `p1`/"Demo"), current `p1`, rows `== [ProfileMenuRow(id: "default", title: "Default", isCurrent: false), ProfileMenuRow(id: "p1", title: "Demo", isCurrent: true)]`.

Settings render: the existing loop already writes `settings-profiles-<light|dark>.png` for the new tab with an empty store. Add these, light and dark:
- `profiles-list-<appearance>`: Default plus "Demo" on `/Users/someone/.config/herdr/sessions/acme/herdr.sock`, Demo current.
- `profiles-new-<appearance>`: form open, name "Demo Video", server name `demo-video`.
- `profiles-locked-<appearance>`.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ProfileCommandsTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ProfileCommands' in scope`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run, render, look**

```bash
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ProfileCommandsTests -skipPackagePluginValidation -derivedDataPath build/dd
RENDER=$PWD/build/renders/settings; mkdir -p $RENDER
TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=$RENDER xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ChromeRenderTests -skipPackagePluginValidation -derivedDataPath build/dd
xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd
open $RENDER/settings-profiles-*.png
```

Expected: green and `** BUILD SUCCEEDED **`. In both appearances:
- The rows align.
- The disabled Delete reads as disabled.
- The form fits without scrolling at 520 tall.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Views/Settings/ProfilesSettingsSection.swift Sources/Flock/Menus/ProfileCommands.swift Tests/FlockChromeRender/ProfileCommandsTests.swift
Scripts/checks.sh
git commit -m "profiles: a Profiles settings tab and a Profile menu"
```

---

### Task 10: End-to-end check in Flock Dev

No new code unless this finds a bug; a bug found here goes back to its owning task's tests first.

- [ ] **Step 1: Targeted runs, then checks**

Run every test class named in Tasks 1 to 9 (both schemes, `-only-testing` per class), then `Scripts/checks.sh`.
Expected: all green; checks print `ok` for every gate.

- [ ] **Step 2: Confirm herdr-chat follows the socket**

With a scratch session running (`herdr --session acme-chatcheck server` started by hand, never the default), run `HERDR_SOCKET_PATH=$HOME/.config/herdr/sessions/acme-chatcheck/herdr.sock <herdr-chat path> status --pane w1:p1` and the same without the variable.
Expected: the two answers differ (the first is about the scratch server's pane). If they match, herdr-chat ignores the variable. In that case, hide Chat when `session.address != .defaultServer` (`ChatMenuModel` and the chat views read it), add a test for that, and commit before going on. Stop the scratch server afterwards only with `HERDR_SOCKET_PATH=<its socket> herdr server stop`, never the default.

- [ ] **Step 3: Build and hand over**

Run: `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev`. Ask Matt to click "New build · Restart" in Flock Dev. Never launch, quit or kill his apps.

- [ ] **Step 4: Walk the acceptance with Matt in Flock Dev**

Each line is one spec acceptance item; record what was seen.

1. Flock > Profile > New Profile…, name "demo", server "New server", server name `demo`, Create and Switch. The window stays open. There are no pins and only the fresh server's first workspace. There are no dock cards and no chat state, the theme and sizes are the defaults, and Board and Herds are absent.
2. `ps -axo pid,command | grep -- "--bridge"`: every bridge names `.../sessions/demo/herdr.sock`, and none names the old socket.
3. `ps -o pid,pgid,sess,command -p $(pgrep -f "herdr --session demo server")`: its pgid and session are its own, not Flock Dev's.
4. Switch back to Default: the same pins on the same workspaces, symbols, completed tabs and recents.
5. Settings > herdr > Server on Default: pick `demo`, then go back to `default`. The second visit to `demo` shows what the first left.
6. Pick a stopped session: the named not-running screen. Start brings it up, and the window attaches within about two seconds.
7. Pick another stopped session and start it from a terminal instead (`herdr --session <name> server`): the window attaches within about two seconds.
8. Custom socket path `/tmp/flock-nothing.sock`: the custom screen, with no Start button.
9. With Flock (production) on the default session, switch Flock Dev's profile to Default. The prompt offers "Stay on <profile>"; choosing it leaves Flock Dev where it was, and the Profile menu's check has not moved.
10. Profiles tab: Delete is disabled on Default and on the current profile. Deleting "demo" from Default removes it, and `defaults read dev.mattstack.Flock.dev.profile.<id>` reports no domain, while `herdr session list` still shows `demo` running.
11. Ask Matt to quit Flock Dev himself. `herdr session list` still shows `demo` running.
12. The locked state is covered by Task 4's tests and the `herdr-server-locked` and `profiles-locked` renders. e2e runs exercise it live; this walk does not relaunch Matt's app with an override.

- [ ] **Step 5: Fix anything found, through the owning task's tests, and commit each fix**
