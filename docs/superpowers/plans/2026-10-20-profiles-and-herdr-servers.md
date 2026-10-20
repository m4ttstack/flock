# Profiles and herdr Server Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let flock keep several profiles, each with its own preferences, its own herdr server and its own id-keyed state per server, and switch between them (or change a profile's server) in place, without quitting.

**Architecture:** Everything `FlockApp.init` builds per socket and per `UserDefaults` moves into one `FlockSession`. A `ProfileSessionController` (FlockCore, generic over the session) owns the current session and runs a switch as guard, teardown, rebuild. Profiles and their suite names live in FlockCore (`ProfileStore`, `ProfileSuites`); server addressing and `herdr session list` parsing live in FlockCore too. Settings gains a Server row (herdr tab) and a Profiles tab; the Flock menu gains a Profile submenu.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Observation, XCTest, CryptoKit (SHA-256 for the socket key), xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-20-profiles-and-herdr-servers-design.md`

## Global Constraints

- Public repo: no employer, customer, host, ticket id or private link in code, fixtures, docs or commit messages. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration or history.
- Tests stay hermetic: no test spawns rt, herdr, herdr-chat or deck, reads `~/.mattstack`, or reaches the network. Stores take injected `UserDefaults` and sources.
- Never `herdr server stop`, never `pane.scroll`, never `layout.apply` on live panes. flock never stops or deletes herdr sessions.
- Child processes get `ToolPath.childEnvironment()`.
- `@MainActor` test classes: statics read in `setUp`/`tearDown` are `nonisolated`.
- Switching never quits flock. One window; no multi-window work.
- With no profile list stored, flock behaves exactly as today (Default profile, default socket, `UserDefaults.standard`).
- `HERDR_SOCKET_PATH` set in flock's environment wins: flock uses it, and both the server picker and profile switching are disabled.
- Default profile id is `default`. Suite names: `<bundle id>.profile.<id>` for preferences, `<bundle id>.profile.<id>.server.<key>` for id-keyed state, `<key>` a stable short hash of the normalized socket path. Default on the default socket uses `UserDefaults.standard` for both.
- Server starts go through `HerdrServerLauncher` (setsid, stdio on /dev/null, `HERDR_MACOS_SERVER_CONTEXT=user`, no `RT_BATCH`, cwd home). A named session starts as `herdr --session <name> server`.
- Run `xcodegen` after adding or removing files; run `Scripts/checks.sh` after `git add`.
- Every build and test uses `-derivedDataPath build/dd` inside the worktree (a path containing "GitHub" trips the worktree guard). Run only the tests for the code you touched.

## Review Focus

1. **A second switch while one is in flight** (two profile clicks in a row): expected to run one switch at a time, never two live sessions. Pinned in Task 4 (`testASwitchRequestedMidSwitchWaitsItsTurn`).
2. **Switching with live transient UI** (rt modal open, parked panes, a pane mid-launcher): teardown must detach every surface, parked ones included, and end rt watches. Pinned in Task 3 (`testShutdownDetachesParkedSurfacesAndEndsRtWatches`).
3. **A custom socket path typed with `~` or a trailing slash, or the default path typed by hand**: expected to resolve to the same server as the menu entry, so its id-keyed state is not split. Pinned in Task 1 (`testTildeAndDefaultSpellingsResolveToTheDefaultServer`).
4. **Blank, duplicate or odd profile and server names**: profile names trim and must be non-empty (duplicates allowed, ids differ); server names must match `[A-Za-z0-9._-]{1,64}`. Pinned in Task 1 (`testServerNameValidation`) and Task 2 (`testCreateRejectsABlankName`).
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
  - `public init(socketPath: String, home: String)` (normalizes with `FlockClientRecord.normalized` after expanding a leading `~`; `<home>/.config/herdr/herdr.sock` is `.defaultServer`, `<home>/.config/herdr/sessions/<name>/herdr.sock` is `.named(name)`, anything else `.custom(normalizedPath)`)
  - `public func socketPath(home: String) -> String`
  - `public var label: String` (`"default"`, the name, or the custom path's parent directory name; replaces `FlockApp.sessionLabel(fromSocketPath:)`)
  - `public var isStartable: Bool` (false only for `.custom`)
  - `public static func isValidSessionName(_ name: String) -> Bool` (`^[A-Za-z0-9._-]{1,64}$`, and not `default`)
  - `public struct HerdrSessionEntry: Equatable, Sendable { public let name: String; public let isRunning: Bool; public let socketPath: String; public let isDefault: Bool }`
  - `public enum HerdrSessionList { public static func parse(_ stdout: Data) -> [HerdrSessionEntry]? }` (nil for output that is not the shape below)

`herdr session list --json` answers (checked against herdr 2026-10-20):

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

    func testTheDefaultSocketIsTheDefaultServer() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/herdr.sock", home: home), .defaultServer)
    }
    func testASessionsSocketIsNamed() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/sessions/acme/herdr.sock", home: home), .named("acme"))
    }
    func testAnythingElseIsCustom() {
        // Not under /tmp: normalizing resolves symlinks, and /tmp is one.
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/acme/x.sock", home: home), .custom("/Users/someone/acme/x.sock"))
    }
    func testTildeAndDefaultSpellingsResolveToTheDefaultServer() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "~/.config/herdr/herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/./herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "~/.config/herdr/sessions/acme/herdr.sock", home: home), .named("acme"))
    }
    func testSocketPathRoundTrips() {
        XCTAssertEqual(HerdrServerAddress.named("acme").socketPath(home: home), "/Users/someone/.config/herdr/sessions/acme/herdr.sock")
        XCTAssertEqual(HerdrServerAddress.defaultServer.socketPath(home: home), "/Users/someone/.config/herdr/herdr.sock")
    }
    func testLabels() {
        XCTAssertEqual(HerdrServerAddress.defaultServer.label, "default")
        XCTAssertEqual(HerdrServerAddress.named("acme").label, "acme")
    }
    func testOnlyCustomIsNotStartable() {
        XCTAssertTrue(HerdrServerAddress.named("acme").isStartable)
        XCTAssertFalse(HerdrServerAddress.custom("/tmp/x.sock").isStartable)
    }
    func testServerNameValidation() {
        XCTAssertTrue(HerdrServerAddress.isValidSessionName("acme-demo_1.2"))
        for bad in ["", " ", "a b", "a/b", "default", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrServerAddress.isValidSessionName(bad), bad)
        }
    }
}
```

`HerdrSessionListTests`: `testParsesEachSession` (the JSON above gives two entries, `acme` not running, `default` with `isDefault`), `testRejectsOutputThatIsNotTheList` (`Data("nope".utf8)` and `{"sessions":3}` give nil).

- [ ] **Step 2: Regenerate and run them to see them fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrServerAddressTests -only-testing:FlockCoreTests/HerdrSessionListTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'HerdrServerAddress' in scope`.

- [ ] **Step 3: Implement both files to the interfaces above**

- [ ] **Step 4: Run the tests again**

Same command. Expected: `** TEST SUCCEEDED **`.

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
- Consumes: `FlockClientRecord.normalized(_:)`.
- Produces:
  - `public struct FlockProfile: Codable, Equatable, Sendable, Identifiable { public static let defaultID = "default"; public let id: String; public var name: String; public var socketPath: String?; public var knownSockets: [String] }` (`socketPath` nil means herdr's default socket; `knownSockets` holds normalized paths, the default socket included once used)
  - `public enum ProfileSuites`:
    - `static func preferencesSuiteName(bundleID: String, profileID: String) -> String?` (nil for `default`)
    - `static func serverSuiteName(bundleID: String, profileID: String, socketPath: String, defaultSocketPath: String) -> String?` (nil only for `default` on the default socket)
    - `static func socketKey(_ socketPath: String) -> String` (first 12 lowercase hex chars of SHA-256 of the normalized path)
    - `static func allSuiteNames(for profile: FlockProfile, bundleID: String, defaultSocketPath: String) -> [String]`
  - `@MainActor @Observable public final class ProfileStore`:
    - `public static let defaultsKey = "flock.profiles"`
    - `public init(userDefaults: UserDefaults = .standard, bundleID: String, defaultSocketPath: String, removeSuite: @escaping (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) })`
    - `public private(set) var profiles: [FlockProfile]`, `public private(set) var currentID: String`, `public var current: FlockProfile { get }`
    - `public func create(name: String, socketPath: String?) -> FlockProfile?` (nil for a blank name; id is a new lowercase UUID string)
    - `public func rename(_ id: String, to name: String)` (blank ignored)
    - `public func setSocket(_ socketPath: String?, for id: String)` (records the normalized path in `knownSockets`)
    - `public func select(_ id: String)`
    - `public func delete(_ id: String) -> Bool` (false for `default` and for `currentID`)

Stored on `userDefaults` as one JSON value `{"profiles":[...],"currentID":"..."}`. Nothing stored reads as one Default profile on the default socket and writes nothing until a change.

- [ ] **Step 1: Write the failing tests**

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
func testSocketKeyIsStableAndIgnoresSpelling() {
    XCTAssertEqual(ProfileSuites.socketKey(acme).count, 12)
    XCTAssertEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(acme.replacingOccurrences(of: "/herdr.sock", with: "/./herdr.sock")))
    XCTAssertNotEqual(ProfileSuites.socketKey(acme), ProfileSuites.socketKey(home))
}
```

(`home` and `acme` are the two socket paths from Task 1's fixtures.)

`ProfileStoreTests` (each test uses `UserDefaults(suiteName: "profile-store-\(UUID())")!` and a `removeSuite` closure that records names):

- `testNothingStoredIsOneDefaultProfile`: one profile, id `default`, name `Default`, `socketPath` nil, `currentID == "default"`, and the defaults key is still unset.
- `testCreateRejectsABlankName`: `create(name: "  ", socketPath: nil)` is nil; `create(name: " Demo ", socketPath: acme)` has name `Demo` and `knownSockets == [acme]`.
- `testChangesPersistAcrossInstances`: create, rename, `setSocket`, `select`; a second `ProfileStore` on the same defaults reads the same `profiles` and `currentID`.
- `testSetSocketRecordsEachServerOnce`: `setSocket(acme)`, `setSocket(nil)`, `setSocket(acme)` leaves `knownSockets == [acme, home]`.
- `testDeleteRemovesEverySuiteAndNothingElse`: a profile that used `acme` and the default socket; `delete` returns true and `removeSuite` saw exactly `ProfileSuites.allSuiteNames(for:)` (three names); the defaults key no longer lists it.
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
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (init around :258-294; new `shutdown()`)
- Modify: `Sources/Flock/Ghostty/HerdrHoldCoordinator.swift`
- Modify: `Sources/Flock/Chat/ChatStore.swift`
- Test: `Tests/FlockCoreTests/SessionViewModelTests.swift` (its private fakes live here)
- Test: `Tests/FlockChromeRender/HerdrHoldCoordinatorTests.swift`, `Tests/FlockChromeRender/ChatStoreTests.swift`

**Interfaces:**
- Produces:
  - `PaneScrollSubscribing.unsubscribeAll()` and `PaneAgentStatusSubscribing.unsubscribeAll()` (cancel every feed)
  - `RtCoordinator.shutdown()` (cancels `watches`, `shutdowns`, `pendingWork`; touches no rt item and no pane)
  - `SessionViewModel.init(..., rtLinkedPaneDefaults: UserDefaults? = nil, ...)`: when non-nil and `rt` is nil, builds `RtCoordinator(client:linkedPanes: RtLinkedPanes(defaults:), notice:)`
  - `SessionViewModel.shutdown() async`: waits on in-flight `paneWork`, detaches every surface in `ghosttySurfaces` (parked included), cancels `promptWatches` and `navigationWatches`, `unsubscribeAll()` on both subscribers, `rt.shutdown()`, `flushPaneTitles()`. Idempotent.
  - `HerdrHoldCoordinator.invalidate()` (removes its observers, invalidates `releaseTimer`)
  - `ChatStore.stop()` (cancels `probeTask` and `peekTask`)

- [ ] **Step 1: Write the failing tests**

In `SessionViewModelTests.swift`, give `FakePaneScrollSubscriber` (and the agent-status fake beside it) a `private(set) var unsubscribedAll = false` set by `unsubscribeAll()`, then:

```swift
func testShutdownDetachesEverySurfaceAndDropsEveryFeed() async {
    let factory = FakeGhosttyPaneFactory()
    let scroll = FakePaneScrollSubscriber()
    let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory, paneScrollSubscriber: scroll)
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p1"))
    _ = await viewModel.attachPane(PaneID(rawValue: "w1:p2"))
    await viewModel.shutdown()
    XCTAssertEqual(factory.surfaces.values.map(\.detachCallCount), [1, 1])
    XCTAssertTrue(scroll.unsubscribedAll)
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
    // as the first test, then a second `await viewModel.shutdown()`:
    XCTAssertEqual(factory.surfaces.values.map(\.detachCallCount), [1, 1])
}

func testRtLinkedPanesUseTheDefaultsTheyAreGiven() {
    let defaults = UserDefaults(suiteName: "rt-linked-\(UUID())")!
    let viewModel = SessionViewModel(client: RecordingCommandClient(), rtLinkedPaneDefaults: defaults)
    viewModel.rt.linkedPanes.record(PaneID(rawValue: "w1:p9"), for: "tok-\(UUID())")
    XCTAssertNotNil(defaults.object(forKey: RtLinkedPanes.defaultsKey))
}
```

(`RtLinkedPanes.defaultsKey` is `flock.rt.linkedPanes`; make it `public static` if it is not already.)

`HerdrHoldCoordinatorTests`: `testInvalidateStopsReactingToActivation` (post `didBecomeActiveNotification` on an injected `NotificationCenter` after `invalidate()`; `take` is not called).
`ChatStoreTests`: `testStopCancelsTheProbe` (`stop()` then `probeTask.isCancelled`).

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/SessionViewModelTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `value of type 'SessionViewModel' has no member 'shutdown'`.

- [ ] **Step 3: Implement the interfaces above**

- [ ] **Step 4: Run the tests again, plus the two Flock-side ones**

Run the Step 2 command, then: `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/HerdrHoldCoordinatorTests -only-testing:FlockChromeRender/ChatStoreTests -skipPackagePluginValidation -derivedDataPath build/dd`
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
- Consumes: `ProfileStore`, `ProfileSuites`, `FlockProfile` (Task 2).
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
}

public struct ProfileSessionEnvironment<Session: ProfileSession> {
    public var bundleID: String
    public var defaultSocketPath: String
    /// `HERDR_SOCKET_PATH` from flock's own environment, when set.
    public var socketOverride: String?
    /// nil suite name means `UserDefaults.standard`.
    public var defaults: @MainActor (String?) -> UserDefaults
    /// false cancels the switch before anything is torn down.
    public var confirmAttach: @MainActor (_ socketPath: String, _ stayingOn: FlockProfile) async -> Bool
    public var register: @MainActor (_ socketPath: String) -> Void
    public var setChildSocket: (_ socketPath: String) -> Void
    public var make: @MainActor (ProfileSessionContext) -> Session
}

@MainActor @Observable public final class ProfileSessionController<Session: ProfileSession> {
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

A switch, in order: refuse when locked or when the target equals the current (profile, socket); `confirmAttach` (return false on no); `await session.shutdown()`; update `ProfileStore` (`select` or `setSocket`); `setChildSocket(new)`; `make(context)`; `register(new)`; `generation += 1`; `await session.start()`. Requests arriving while one runs wait for it (a serial queue of `Task`s, not a drop). `init` builds the first session without calling `start`, `confirmAttach` or `register`; `FlockApp` launch does those (Task 6).

- [ ] **Step 1: Write the failing tests**

Use a `FakeSession: ProfileSession` that appends `"start <socket>"` / `"shutdown <socket>"` to a shared `[String]` log, and an environment whose closures append `"confirm"`, `"register <socket>"`, `"child <socket>"`, `"make <profile id> <socket>"`. Suites come from `defaults: { $0.map { UserDefaults(suiteName: "psc-\(runID)-\($0)")! } ?? standardStandIn }` where `standardStandIn` is a per-test suite.

- `testLaunchBuildsTheCurrentProfileOnItsSocketAndStartsNothing`: log is `["make default <home>"]`; `generation == 0`.
- `testASwitchRunsInOrder`: `switchTo(p1)` gives `["confirm", "shutdown <home>", "child <acme>", "make p1 <acme>", "register <acme>", "start <acme>"]` after the launch entry; `generation == 1`; store `currentID == p1`.
- `testARefusedSwitchLeavesEverythingAsItWas`: `confirmAttach` returns false; result false; no shutdown in the log; `currentID` unchanged; `generation == 0`.
- `testChangingServerKeepsTheProfileAndRemembersBothServers`: `changeServer(to: acme)` on Default; `make default <acme>`; `current.knownSockets == [home, acme]` normalized.
- `testEachPairGetsItsOwnIdStateSuite`: the contexts handed to `make` for (default, home), (default, acme), (p1, acme) have three distinct `idState` objects, and the first is `standardStandIn`.
- `testLockedRefusesBothKinds`: `socketOverride` set; both calls return false; nothing logged after launch; launch `make` used the override socket.
- `testSwitchingToWhereYouAreDoesNothing`: `switchTo(default)` from Default returns false; nothing logged.
- `testASwitchRequestedMidSwitchWaitsItsTurn`: `FakeSession.shutdown` suspends on a continuation the test resumes; fire `switchTo(p1)` and `switchTo(p2)` without awaiting the first; resume; the log shows p1's full sequence before p2's `confirm`, and exactly one `start` follows each `make`.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/ProfileSessionControllerTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ProfileSessionController' in scope`.

- [ ] **Step 3: Implement `ProfileSessionController.swift` to the interface above**

- [ ] **Step 4: Run the tests again**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Profiles/ProfileSessionController.swift Tests/FlockCoreTests/ProfileSessionControllerTests.swift
Scripts/checks.sh
git commit -m "profiles: switch sessions in place, guard first, one at a time"
```

---

### Task 5: Child tools follow the session; named servers start; the guard can cancel a switch

**Files:**
- Modify: `Sources/Flock/Environment/ToolPath.swift`
- Modify: `Sources/Flock/Herdr/HerdrServerLauncher.swift`
- Create: `Sources/Flock/Herdr/HerdrSessionLister.swift`
- Modify: `Sources/Flock/Environment/FlockClientGuard.swift`
- Test: `Tests/FlockChromeRender/NoHerdrScreenTests.swift` (launcher env tests live here), `Tests/FlockChromeRender/ToolPathEnvironmentTests.swift` (new)

**Interfaces:**
- Consumes: `HerdrSessionList.parse` (Task 1).
- Produces:
  - `ToolPath.setHerdrSocket(_ socketPath: String)` (stored behind an `OSAllocatedUnfairLock<String?>`; `childEnvironment` reads it off the main actor)
  - `ToolPath.childEnvironment(base: [String: String], path: String, herdrSocket: String?) -> [String: String]` (the pure part; sets `PATH`, `RT_BATCH=1`, and `HERDR_SOCKET_PATH` when `herdrSocket` is non-nil); `childEnvironment()` calls it with the process env, `resolved` and the stored socket
  - `HerdrServerLauncher.start(session: String? = nil) -> Result<Void, Failure>` (argv `[binary, "--session", name, "server"]` when named, else `[binary, "server"]`)
  - `HerdrServerLauncher.environment(from: [String: String], session: String? = nil)`: as today, plus drops `HERDR_SOCKET_PATH` when `session` is non-nil (`--session` names the socket)
  - `enum HerdrSessionLister { static func list() async -> [HerdrSessionEntry]? }` (`herdr session list --json` through `ToolRunner`, 5 s deadline, child environment)
  - `FlockClientGuard.register(socketPath: String)` (writes this pid's record; installs the will-terminate unregister once per process)
  - `FlockClientGuard.confirmAttach(socketPath: String, defaultSocketPath: String, stayingOn: FlockProfile) async -> Bool` (same conflict check as launch; buttons "Quit <other>", "Stay on <profile name>", "Keep Both"; Stay returns false, quitting the other waits as today, Keep Both returns true)
  - `FlockClientGuard.settle(...)` keeps its launch behaviour, built on `register` and the shared conflict check

- [ ] **Step 1: Write the failing tests**

```swift
func testANamedServerStartsWithoutTheInheritedSocket() {
    let environment = HerdrServerLauncher.environment(from: ["HERDR_SOCKET_PATH": "/tmp/h.sock", "PATH": "/usr/bin"], session: "acme")
    XCTAssertNil(environment["HERDR_SOCKET_PATH"])
    XCTAssertEqual(environment["HERDR_MACOS_SERVER_CONTEXT"], "user")
}
```

(`testTheServerStartsWithoutRtsBatchFlag` stays as is: no session keeps the socket.)

`ToolPathEnvironmentTests`: `testChildToolsAreToldTheSessionsSocket` (`herdrSocket: acme` sets `HERDR_SOCKET_PATH == acme`, `RT_BATCH == "1"`, `PATH` the given one), `testNoSocketLeavesTheInheritedOne` (`herdrSocket: nil` keeps a base `HERDR_SOCKET_PATH`).

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/NoHerdrScreenTests -only-testing:FlockChromeRender/ToolPathEnvironmentTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails on the missing `session:` parameter.

- [ ] **Step 3: Implement the interfaces above**

The guard's alert is AppKit and stays untested; keep the conflict decision in `FlockClientConflict.others` as today.

- [ ] **Step 4: Run the tests again**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Herdr/HerdrSessionLister.swift Tests/FlockChromeRender/ToolPathEnvironmentTests.swift
Scripts/checks.sh
git commit -m "child tools follow the session's socket; start named herdr servers; guard can cancel a switch"
```

---

### Task 6: `FlockSession`, and `FlockApp` built on it

The largest task: a move, not new behaviour. After it, flock with no profile list stored must behave exactly as before.

**Files:**
- Create: `Sources/Flock/Environment/FlockSession.swift`
- Modify: `Sources/Flock/FlockApp.swift`
- Test: `Tests/FlockChromeRender/FlockSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 2 to 5.
- Produces:
  - `@MainActor @Observable final class FlockSession: ProfileSession`
  - `init(context: ProfileSessionContext, ghosttyHost: GhosttyHost?, board: BoardStore, herdProgress: HerdProgressStore, resnapshotInterval: Duration?)`
  - Stored, all built in `init` exactly as `FlockApp.init` builds them today, each from the suite given below: `herdrStore`, `viewModel`, `undoJournal`, `toastCenter`, `chatStore`, `rearrangeMode`, `dragCoordinator`, `dividerDragCoordinator`, `herdrHoldCoordinator`, `commandPalette`, `workspaceSwitcher`, `tabSwitcher`, and every preference store
  - `let socketPath: String`, `let address: HerdrServerAddress`, `let profile: FlockProfile`
  - `start()`: `herdrStore.start()`
  - `shutdown()`: `herdrHoldCoordinator.invalidate()`, `herdrStore.stop()`, `await viewModel.shutdown()`, `chatStore.stop()`, `toastCenter` cleared

Which `UserDefaults` each store gets (the spec's section 1, corrected where noted):

| `context.preferences` | `context.idState` | stays app-level on `.standard` |
|---|---|---|
| `ThemeStore`, `TerminalTextSizeStore`, `RtModalSizeStore`, `RtModalTextSizeStore`, `TopBarLabelStore`, `OptionAsAltStore`, `ScrollSpeedStore`, `LinkTrustStore`, `NotificationLifetimeStore`, `OneTitleStore`, `AgentCloseWarningStore`, `StartingFolderStore`, `RearrangeAfterMoveStore`, `MissionBottomLineStore`, `OverviewReturnStore`, `OverviewInclusionStore`, `AllWorkspacesModeStore`, `RailWidthStore`, `SectionCollapseStore`, `PaletteRecentsStore` | `WorkspaceIdentityStore`, `TopBarOverlaySizeStore` (keyed by pin, and pins are id state), `AttentionToastArchive`, `PaneLastChangeArchive`, `WorkspaceSwitcher`, `TabSwitcher`, and the view model's `rightClickDefaults`, `completedTabDefaults`, `paneTitleDefaults`, `pinnedWorkspaceDefaults`, `rtLinkedPaneDefaults` | `BoardStore` (its logo cache is the same for every profile, so it is not per profile as the spec listed), `HerdrMousePatchStore`, `DevRebuild`, `MainWindowFrameKeeper`, `ApplePersistenceIgnoreState` |

App-level objects that stay on `FlockApp`: `GhosttyHost` (one libghostty app; `onClipboardWrite` is re-pointed at the new session's `toastCenter` each switch), `ProfileStore`, the `ProfileSessionController<FlockSession>`, `BoardStore`, `HerdProgressStore`, `CswapStore`, `HerdrToolStore`, `HerdrMousePatchStore`, `HerdrUpdateStore` (its `installedVersion` reads the controller's current session), `SettingsTabSelection`, `CommandLineToolStore`, `DevBuildWatcher`, `DevRebuild`, the updater.

`FlockApp` changes:
- `init`: build `ProfileStore(bundleID: Bundle.main.bundleIdentifier ?? "dev.mattstack.Flock", defaultSocketPath:)`, then the controller with `FlockClientGuard.confirmAttach`, `FlockClientGuard.register`, `ToolPath.setHerdrSocket` and a `make` that builds `FlockSession`. `socketOverride` is today's `HERDR_SOCKET_PATH` read. `defaultSocketPath` and `sessionLabel` come from `HerdrServerAddress`.
- Each former `@State` store becomes a computed property reading `controller.session`, so `body` and the commands keep their names.
- The window's content gets `.id(controller.generation)`; the `.task`, `.onReceive` and `.onChange` modifiers sit outside it so they run once per launch. The launch `.task` calls `ToolPath.setHerdrSocket`, `FlockClientGuard.settle`, then `controller.session.start()`.
- `FlockAppDelegate.onTerminate` gets one closure that flushes the current session's pane titles.
- `FLOCK_RESNAPSHOT_SECONDS` still applies, through `resnapshotInterval`.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class FlockSessionTests: XCTestCase {
    func testPreferencesAndIdStateLandInTheirOwnSuites() {
        let preferences = UserDefaults(suiteName: "fs-prefs-\(UUID())")!
        let idState = UserDefaults(suiteName: "fs-ids-\(UUID())")!
        preferences.set("one-light", forKey: ThemeStore.defaultsKey)
        let session = FlockSession(
            context: ProfileSessionContext(
                profile: FlockProfile(id: "p1", name: "Acme", socketPath: "/tmp/acme.sock", knownSockets: ["/tmp/acme.sock"]),
                socketPath: "/tmp/acme.sock", preferences: preferences, idState: idState
            ),
            ghosttyHost: nil, board: BoardStore(sources: .init(readSetting: { nil }, fetchLogo: { nil }), userDefaults: preferences),
            herdProgress: HerdProgressStore(sources: HerdProgressSources(listHerds: { nil }, readStatus: { _ in nil })),
            resnapshotInterval: nil
        )
        XCTAssertEqual(session.themeStore.active.id, "one-light")
        session.workspaceIdentityStore.setOverride(WorkspaceSymbols.all[0], for: "w1")
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

Run the Step 2 command, then `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ChromeRenderTests -only-testing:FlockChromeRender/NoHerdrScreenTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: `** TEST SUCCEEDED **` for both.

- [ ] **Step 5: Check nothing changed for an existing install**

Run: `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev` and ask Matt to click "New build · Restart" in Flock Dev.
Expected: Flock Dev opens on its usual server with its pins, symbols, theme and text size as before. `defaults read dev.mattstack.Flock.dev flock.profiles` reports the key does not exist.

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
- Modify: `Sources/Flock/FlockApp.swift` (`notRunningCopy`, `startHerdr`)
- Modify: `Sources/FlockCore/Store/HerdrStore.swift:639-643` (`defaultBackoff`)
- Test: `Tests/FlockChromeRender/NoHerdrScreenTests.swift`, `Tests/FlockCoreTests/HerdrStoreBackoffTests.swift` (new)

**Interfaces:**
- Consumes: `HerdrServerAddress` (Task 1), `HerdrServerLauncher.start(session:)` (Task 5), the session's `address`.
- Produces: `static func notRunning(for address: HerdrServerAddress) -> NoHerdrScreen.Copy`. `.defaultServer` returns today's `notRunning` copy unchanged. Otherwise:

| address | headline | body | hint |
|---|---|---|---|
| `.named(n)` | `The herdr server “n” isn't running.` | `flock is checking for it and will attach as soon as it starts.` | `Start it here, or run herdr --session n in a terminal.` |
| `.custom(p)` | `Nothing is answering at p.` | `flock is checking and will attach as soon as a herdr server is listening there.` | `Start that server however it is normally started.` |

- `.custom` gets no primary action. `.named` gets "Start herdr" calling `HerdrServerLauncher.start(session: n)`, with the existing starting and failure states.
- `defaultBackoff` caps at 2,000 ms instead of 15,000, so a server started outside flock is picked up within about two seconds.

- [ ] **Step 1: Write the failing tests**

`testNamedAndCustomCopy` asserts the table above. `testCustomHasNoStartButton` renders `.custom` and finds no button. `HerdrStoreBackoffTests.testBackoffNeverWaitsMoreThanTwoSeconds`: `HerdrStore.defaultBackoff(attempt: 1) == .milliseconds(500)` and `defaultBackoff(attempt: 50) == .seconds(2)`.

Extend `testRendersOverTheThemesChromeWithNoButtonByDefault`'s theme loop (dark `tokyoNight` and `one-light`) to also write `no-herdr-named-<theme>.png` and `no-herdr-custom-<theme>.png` to `FLOCK_CHROME_RENDER_DIR`.

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/NoHerdrScreenTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `type 'NoHerdrScreen' has no member 'notRunning(for:)'`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run the tests, then render and look**

Run the Step 2 command and `-only-testing:FlockCoreTests/HerdrStoreBackoffTests` on the Flock scheme. Then: `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=build/renders/no-herdr xcodebuild test -scheme FlockChromeRender ... -only-testing:FlockChromeRender/NoHerdrScreenTests` and open the PNGs in Preview.
Expected: green, and in both themes the session name or path reads in full, with no clipping.

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
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift` (herdr tab; init gains `serverPicker: ServerPicker?`)
- Modify: `Sources/Flock/FlockApp.swift` (builds the picker, passes it)
- Test: `Tests/FlockChromeRender/ServerPickerTests.swift`, `Tests/FlockChromeRender/ChromeRenderTests.swift` (settings render cases)

**Interfaces:**
- Consumes: `HerdrSessionLister.list`, `HerdrServerLauncher.start(session:)`, `ProfileSessionController.changeServer(to:)`, `isLocked`, `socketPath`.
- Produces: `@MainActor @Observable final class ServerPicker`:
  - `init(list: @escaping () async -> [HerdrSessionEntry]?, start: @escaping (String) -> Result<Void, HerdrServerLauncher.Failure>, choose: @escaping (String?) async -> Bool, currentSocket: @escaping () -> String, isLocked: Bool, home: String)`
  - `private(set) var entries: [HerdrSessionEntry]`, `private(set) var failure: String?`
  - `func refresh() async` (called when the menu opens and when the section appears)
  - `func choose(_ entry: HerdrSessionEntry) async` (`choose(nil)` for the default entry, else its socket)
  - `func startNew(name: String) async` (rejects invalid names via `HerdrServerAddress.isValidSessionName`, sets `failure`; else `start(name)` then `choose` the new socket)
  - `func chooseCustom(path: String) async` (empty ignored; passes the path through `HerdrServerAddress` so a spelling of a known server picks that server)

The section has one row, "Server", with a menu: each entry as `name` plus a trailing "running" or "stopped" note, a check on the current; a divider; "New Server…", which shows a name field and a Start button inline under the row; "Custom Socket Path…", which shows a path field and a Use button inline. When locked: the menu is disabled and the row's note reads `Set by HERDR_SOCKET_PATH: <path>`.

- [ ] **Step 1: Write the failing tests**

`ServerPickerTests` with closures that record calls:
- `testChoosingDefaultPassesNil`, `testChoosingANamedEntryPassesItsSocket`
- `testStartNewStartsThenChoosesTheNewSocket`: `start` saw `"demo"`, `choose` saw `/Users/someone/.config/herdr/sessions/demo/herdr.sock`
- `testStartNewRejectsABadNameWithoutStarting`: `"a b"` sets `failure`, `start` never called
- `testAStartFailureIsShownAndNothingIsChosen`
- `testCustomPathThatSpellsTheDefaultChoosesDefault`: `"~/.config/herdr/herdr.sock"` makes `choose(nil)`

Settings render: add `herdr-server-<appearance>` and `herdr-server-locked-<appearance>` cases (light and dark) to the existing settings render loop, with a `ServerPicker` over canned entries `default` (running) and `acme` (stopped).

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ServerPickerTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ServerPicker' in scope`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run, render, look**

Run Step 2, then `TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=build/renders/settings xcodebuild test -scheme FlockChromeRender ... -only-testing:FlockChromeRender/ChromeRenderTests` and open the `herdr-server-*` PNGs in Preview.
Expected: green. Both appearances: the row sits under the update and mouse patch rows, the locked note is readable, nothing clips at 560 wide.

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
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift` (`SettingsTab.profiles`, title "Profiles", symbol `person.2`, placed after `.general`; init gains `profiles: ProfileStore?` and `switchProfile: (String) async -> Void`)
- Modify: `Sources/Flock/FlockApp.swift` (`.commands` adds `ProfileCommands`)
- Test: `Tests/FlockChromeRender/ChromeRenderTests.swift` (settings render cases), `Tests/FlockChromeRender/ProfileCommandsTests.swift`

**Interfaces:**
- Consumes: `ProfileStore` (Task 2), `ProfileSessionController.switchTo(profileID:)` and `isLocked` (Task 4), `ServerPicker` (Task 8) for the new-profile server choice, `SettingsTabSelection`.
- Produces:
  - `struct ProfileCommands: Commands`, placed with `CommandGroup(after: .appSettings)`: a `Menu("Profile")` listing each profile by name with a checkmark on the current (picking one calls `switchTo`), a divider, "New Profile…" and "Manage Profiles…". Both of the last two set `settingsTabSelection.tab = .profiles` and call `openSettings()`. "New Profile…" also sets `ProfilesSettingsSection`'s new-profile form open (a flag on `SettingsTabSelection`: `var opensNewProfile = false`). All profile items are disabled when locked.
  - `static func rows(profiles: [FlockProfile], currentID: String) -> [(id: String, title: String, isCurrent: Bool)]` on `ProfileCommands`, for the test.
  - `ProfilesSettingsSection`: one row per profile (name, its server's `HerdrServerAddress.label`, "Current" on the current), with Switch, Rename (inline field) and Delete (disabled for Default and for the current; a confirmation alert names the profile and says its herdr server keeps running). Below: a "New Profile" form with a Name field and a Server menu whose first, preselected entry is `New server “<name>”` (enabled only while the name is a valid session name), then the listed sessions. "Create and Switch" creates the profile on the chosen socket (starting the new server first when that entry is chosen) and switches to it. When locked, the whole tab shows `Profiles are off while HERDR_SOCKET_PATH is set.` and nothing else.

- [ ] **Step 1: Write the failing tests**

`ProfileCommandsTests.testRowsListEveryProfileAndCheckTheCurrent`: two profiles, current `p1`, rows `[("default", "Default", false), ("p1", "Demo", true)]`.

Settings render: `profiles-<appearance>` (Default plus `Demo` on `acme`, Demo current), `profiles-new-<appearance>` (form open with name `demo`), `profiles-locked-<appearance>`, light and dark.

- [ ] **Step 2: Regenerate and run to see them fail**

Run: `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/ProfileCommandsTests -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: build fails, `cannot find 'ProfileCommands' in scope`.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run, render, look**

As Task 8 Step 4, opening the `profiles-*` PNGs.
Expected: green. Both appearances: rows align, the disabled Delete reads as disabled, the form fits without scrolling at 520 tall.

- [ ] **Step 5: Commit**

```bash
git add -u Sources Tests && git add Sources/Flock/Views/Settings/ProfilesSettingsSection.swift Sources/Flock/Menus/ProfileCommands.swift Tests/FlockChromeRender/ProfileCommandsTests.swift
Scripts/checks.sh
git commit -m "profiles: a Profiles settings tab and a Profile menu"
```

---

### Task 10: End-to-end check in Flock Dev

No new code unless this finds a bug; a bug found here goes back to its owning task's tests first.

- [ ] **Step 1: Full targeted runs, then checks**

Run every test class named in Tasks 1 to 9 (both schemes, `-only-testing` per class), then `Scripts/checks.sh`.
Expected: all green; checks print `ok` for every gate.

- [ ] **Step 2: Build and hand over**

Run: `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev`. Ask Matt to click "New build · Restart" in Flock Dev. Never launch, quit or kill his apps.

- [ ] **Step 3: Walk the acceptance with Matt in Flock Dev**

Each line is one spec acceptance item; record what was seen.
1. Flock > Profile > New Profile…, name `demo`, server `New server “demo”`, Create and Switch: the window stays open, the rail is empty, no dock cards, default theme and sizes, no Board or Herds, no chat state on panes.
2. `ps -axo pid,command | grep -- "--bridge"`: every bridge names `.../sessions/demo/herdr.sock`; none names the old socket.
3. `ps -o pid,pgid,sess,command -p $(pgrep -f "herdr --session demo server")`: its pgid and session are its own, not Flock Dev's.
4. Switch back to Default: same pins on the same workspaces, symbols, completed tabs and recents.
5. Settings > herdr > Server on Default: pick `demo`, then back to `default`; the second visit to `demo` shows what the first left.
6. Pick a stopped session: the named not-running screen; Start brings it up and the window attaches within about two seconds.
7. Custom socket path `/tmp/flock-nothing.sock`: the custom screen with no Start button.
8. Profiles tab: Delete is disabled on Default and on the current profile; deleting `demo` from Default removes it (`defaults read dev.mattstack.Flock.dev.profile.<id>` reports no domain) and `herdr session list` still shows `demo` running.

- [ ] **Step 4: Fix anything found, through the owning task's tests, and commit each fix**
