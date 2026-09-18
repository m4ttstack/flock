# Chat in flock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every feature of the `m4ttstack.chat` herdr plugin works inside flock as
a Mac app, without a prefix key, and flock has no chat in it at all on a machine
that does not have mattstack.

**Architecture:** flock runs the `herdr-chat` binary's `--json` verbs as a
subprocess and draws the answers natively. The decisions (which argv a verb
becomes, what a status means for the buttons, whether chat is present at all)
are pure code in `FlockCore`; the process call and the SwiftUI views are in
`Sources/Flock`. A chat button in each pane's chrome opens a popover that is
the plugin's launcher, and the other views replace the popover's content.

**Tech Stack:** Swift, SwiftUI, AppKit (`Process`, `NSPopover` via SwiftUI's
`.popover`), `Codable`.

**Spec:** `docs/superpowers/specs/2026-09-18-flock-chat-design.md`

**Designs:** `docs/design/chat/` (`flock-chat.pen` is the source; the PNGs are
`trigger-and-placement`, `popover-signed-out`, `popover-signed-in`, `peek`,
`quick-send`, `broadcast`, `menu-bar`).

**The dependency is shipped.** `herdr-chat` main carries the headless surface as
of `a3d9829`, and its README's "Headless use" section is the contract this plan
reads. Every shape below was taken from that table, not from the spec.

## Global Constraints

- **flock is a herdr client that knows about mattstack where it helps.** On a
  machine without mattstack, chat is absent, not broken: no chat button on any
  pane, no Chat menu, no dialogue explaining what is missing.
- Absence is decided by the resolver, never by catching an error. Code that
  reaches a chat verb has already established the binary exists, so a failure
  from there on is a real failure worth reporting.
- **Probe once per launch, cache the answer, never on the main actor.** A recent
  investigation found a login-shell PATH probe blocking the main actor for up to
  334ms; do not reintroduce that shape.
- **Every verb call has a deadline.** A hung `rt` daemon fails the call and
  raises a toast; it never leaves a spinner up forever and never blocks quit.
- Decisions are pure code in `FlockCore`, driven in tests over parsed JSON.
  Never over a live process: no test spawns `herdr-chat`, `rt`, `herdr` or
  `deck`.
- Errors reach the user as a flock toast, and the popover keeps what was typed.
- No em dashes or en dashes anywhere, including comments and commit messages.
- Comments state a constraint the code cannot show. No narration, no
  reviewer-facing justification, and never a reference to a task, a review, or
  this plan.
- Commit messages: short, lowercase, imperative, describing the rule the code
  now follows. Read `git log --oneline -15` for the house voice.
- Tests: `bash Scripts/build.sh`, then
  `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests`
  and `xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS'`.
  **FlockChromeRender is its own scheme**; `-only-testing` against the Flock
  scheme fails for it.

---

## The contract, verbatim from herdr-chat's README

Every task reads from this table rather than re-deriving it.

| Verb | Argv | Keys it prints |
| --- | --- | --- |
| status | `status --json --pane <id>` | `handle`, `state`, `pane`, `signedIn`, `rooms` |
| sign-in | `sign-in --json --pane <id>` | the same five, read back after the sign |
| sign-out | `sign-out --json --pane <id>` | the same five |
| peek | `peek --json` | `buddies`, `rooms` |
| targets | `targets --json` | `rooms`, `people` |
| quick-send | `quick-send --json --to <#room\|@handle> --body <text>` | `ok`, `to` |
| broadcast | `broadcast --json --panes <id,id> --body <text>` | `ok`, `results` |
| jump | `jump --json --handle <handle>` | `paneId`, `workspace`, `handle` |
| open-viewer | `open-viewer --json` (`--room <room>` optional) | `url` |

Nested: a peek buddy is `handle`, `paneId`, `status`, `repo`, `branch`, `title`,
`unread`, `mentions`; a peek room is `room`, `unread`, `mentions`; a broadcast
result is `paneId`, `ok`, `delivered`, `error`.

Five rules that shape the Swift:

1. **A failure is `{"error":"..."}` on stdout with a non-zero exit**, not stderr.
2. **Absent values are `null`, never a missing key.** `handle` and `pane` on a
   status, a buddy's `paneId`/`repo`/`branch`/`title`, a result's `error`.
3. **`quick-send`'s `ok` is always true.** It is not a discriminator: a failed
   send arrives as the error envelope. Do not branch on it.
4. **`broadcast`'s `ok` is real**, false as soon as any pane refused. Each result
   carries `delivered`: `accepted`, `queued` or `refused`, and only `refused` is
   a failure. A queued message is one rt has taken responsibility for.
5. **Broadcast's two failures differ in exit code.** Every pane refusing exits
   **0** with `ok:false` and a result per pane. An empty `--panes` exits **1**
   with the error envelope. A caller must tell them apart.

`targets` prints prefixed strings (`#room`, `@handle`) and `quick-send --to`
takes one back; a bare name is refused.

---

## File Structure

**New in `Sources/FlockCore/Chat/`** (pure, tested over data):
- `ChatVerb.swift`: the nine verbs and the argv each becomes.
- `ChatShapes.swift`: the `Decodable` shapes, one per row above.
- `ChatOutcome.swift`: parsing one run's stdout plus exit code into a result or
  a typed failure.
- `ChatPresence.swift`: what a status object means for the popover (which
  buttons are live, what the header reads).
- `ChatBroadcastSummary.swift`: what a broadcast result means for the toast.

**New in `Sources/Flock/Chat/`** (AppKit and SwiftUI):
- `ChatToolLocator.swift`: where the binary is, or that it is absent.
- `ChatRunner.swift`: the `Process` call, the deadline, and the protocol
  `FlockCore` decisions are written against.
- `ChatStore.swift`: the `@Observable` store, per-pane status and availability.
- `ChatPopover.swift`, `ChatPeekView.swift`, `ChatQuickSendView.swift`,
  `ChatBroadcastView.swift`: the views.
- `ChatCommands.swift`: the Chat menu.

**Modified:**
- `Sources/Flock/Views/PaneCellView.swift`: the chat button in the chrome.
- `Sources/Flock/FlockApp.swift`: the store, and the Chat menu group.

---

### Task 1: The verbs, as argv

**Files:**
- Create: `Sources/FlockCore/Chat/ChatVerb.swift`
- Test: `Tests/FlockCoreTests/ChatVerbTests.swift`

**Interfaces:**
- Produces: `ChatVerb` with cases `status(pane:)`, `signIn(pane:)`,
  `signOut(pane:)`, `peek`, `targets`, `quickSend(to:body:)`,
  `broadcast(panes:body:)`, `jump(handle:)`, `openViewer(room:)`, and
  `var arguments: [String]`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlockCore

final class ChatVerbTests: XCTestCase {
    func testStatusNamesThePaneItAsksAbout() {
        XCTAssertEqual(
            ChatVerb.status(pane: "w1:p1").arguments,
            ["status", "--json", "--pane", "w1:p1"]
        )
    }

    /// The panes are one comma-separated argument, which is what the verb's
    /// own value delimiter expects; one flag per pane is a different CLI.
    func testBroadcastJoinsItsPanesIntoOneArgument() {
        XCTAssertEqual(
            ChatVerb.broadcast(panes: ["w1:p1", "w2:p7"], body: "pausing").arguments,
            ["broadcast", "--json", "--panes", "w1:p1,w2:p7", "--body", "pausing"]
        )
    }

    /// A room is passed with its prefix, because the far side refuses a bare
    /// name rather than guessing between a room and a person.
    func testQuickSendPassesTheTargetPrefixThrough() {
        XCTAssertEqual(
            ChatVerb.quickSend(to: "#rt", body: "hi").arguments,
            ["quick-send", "--json", "--to", "#rt", "--body", "hi"]
        )
    }

    func testOpenViewerOmitsTheRoomFlagWhenThereIsNoRoom() {
        XCTAssertEqual(ChatVerb.openViewer(room: nil).arguments, ["open-viewer", "--json"])
        XCTAssertEqual(
            ChatVerb.openViewer(room: "rt").arguments,
            ["open-viewer", "--json", "--room", "rt"]
        )
    }

    /// A body is never shell-quoted here: `Process` takes an argument vector,
    /// so a body holding spaces, quotes or a leading dash is one argument and
    /// needs no escaping. Quoting it would send the quotes.
    func testABodyWithShellMetacharactersIsOneUnescapedArgument() {
        let body = "don't \"ship\"; --now"
        XCTAssertEqual(ChatVerb.quickSend(to: "@scout", body: body).arguments.last, body)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/ChatVerbTests`
Expected: FAIL to compile with "cannot find 'ChatVerb' in scope". Add the type
with `arguments` returning `[]` so the next run fails on an assertion instead,
then continue.

- [ ] **Step 3: Implement**

```swift
/// The nine headless verbs, each as the argument vector it becomes.
///
/// `Process` takes an argument vector rather than a command line, so nothing
/// here is quoted or escaped: a body holding spaces or a leading dash is one
/// argument, and quoting it would send the quotes.
public enum ChatVerb: Equatable, Sendable {
    case status(pane: String)
    case signIn(pane: String)
    case signOut(pane: String)
    case peek
    case targets
    case quickSend(to: String, body: String)
    case broadcast(panes: [String], body: String)
    case jump(handle: String)
    case openViewer(room: String?)

    public var arguments: [String] {
        switch self {
        case let .status(pane): ["status", "--json", "--pane", pane]
        case let .signIn(pane): ["sign-in", "--json", "--pane", pane]
        case let .signOut(pane): ["sign-out", "--json", "--pane", pane]
        case .peek: ["peek", "--json"]
        case .targets: ["targets", "--json"]
        case let .quickSend(to, body): ["quick-send", "--json", "--to", to, "--body", body]
        case let .broadcast(panes, body):
            ["broadcast", "--json", "--panes", panes.joined(separator: ","), "--body", body]
        case let .jump(handle): ["jump", "--json", "--handle", handle]
        case let .openViewer(room):
            ["open-viewer", "--json"] + (room.map { ["--room", $0] } ?? [])
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Chat/ChatVerb.swift Tests/FlockCoreTests/ChatVerbTests.swift
git commit -m "chat: a verb is the argument vector it becomes"
```

---

### Task 2: The wire shapes, and what a run answered

**Files:**
- Create: `Sources/FlockCore/Chat/ChatShapes.swift`, `Sources/FlockCore/Chat/ChatOutcome.swift`
- Test: `Tests/FlockCoreTests/ChatShapesTests.swift`, `Tests/FlockCoreTests/ChatOutcomeTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ChatStatus { handle: String?, state: String, pane: String?, signedIn: Bool, rooms: [String] }`
  - `ChatPeek { buddies: [ChatBuddy], rooms: [ChatPeekRoom] }`,
    `ChatBuddy { handle, paneID, status, repo, branch, title, unread, mentions }`,
    `ChatPeekRoom { room, unread, mentions }`
  - `ChatTargets { rooms: [String], people: [String] }`
  - `ChatSent { to: String }`
  - `ChatBroadcast { ok: Bool, results: [ChatBroadcastResult] }`,
    `ChatBroadcastResult { paneID, ok, delivered, error }`
  - `ChatJump { paneID: String, workspace: String, handle: String }`
  - `ChatViewer { url: String }`
  - `ChatFailure: Error { message: String }`
  - `ChatOutcome.decode<T: Decodable>(_ type: T.Type, stdout: Data, exitCode: Int32) throws -> T`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

final class ChatOutcomeTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testASuccessfulRunDecodesItsShape() throws {
        let json = #"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":["#rt"]}"#
        let status = try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 0)
        XCTAssertEqual(status.handle, "kay")
        XCTAssertTrue(status.signedIn)
        XCTAssertEqual(status.rooms, ["#rt"])
    }

    /// The far side prints its failure on stdout, not stderr, and exits
    /// non-zero. Reading stderr for it would find nothing.
    func testAFailureIsReadFromStdoutAndCarriesItsMessage() {
        let json = #"{"error":"pane is required"}"#
        XCTAssertThrowsError(try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 1)) {
            XCTAssertEqual(($0 as? ChatFailure)?.message, "pane is required")
        }
    }

    /// A non-zero exit with unreadable output is still a failure, and the user
    /// gets something to act on rather than a decode error about JSON.
    func testANonZeroExitWithNoEnvelopeStillFails() {
        XCTAssertThrowsError(try ChatOutcome.decode(ChatStatus.self, stdout: data("boom"), exitCode: 2)) {
            XCTAssertFalse(($0 as? ChatFailure)?.message.isEmpty ?? true)
        }
    }

    /// Absent is null, never a missing key, so an optional stays optional and
    /// a signed-out pane decodes rather than throwing.
    func testNullsDecodeAsAbsentRatherThanFailing() throws {
        let json = #"{"handle":null,"state":"not signed in","pane":null,"signedIn":false,"rooms":[]}"#
        let status = try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 0)
        XCTAssertNil(status.handle)
        XCTAssertNil(status.pane)
        XCTAssertFalse(status.signedIn)
    }

    /// Every pane refusing exits 0 with ok:false and a result per pane, which
    /// is a decodable answer rather than an error. Treating the exit code as
    /// the whole story would lose the per-pane detail.
    func testABroadcastWhereEveryPaneRefusedDecodesRatherThanThrowing() throws {
        let json = """
        {"ok":false,"results":[{"paneId":"w1:p1","ok":false,"delivered":"refused","error":"not signed in"}]}
        """
        let out = try ChatOutcome.decode(ChatBroadcast.self, stdout: data(json), exitCode: 0)
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.results.first?.error, "not signed in")
    }
}
```

And for the shapes, one test that the wire names map:

```swift
final class ChatShapesTests: XCTestCase {
    /// The far side prints paneId; Swift spells it paneID. A rename on either
    /// side breaks this silently, so it is asserted rather than assumed.
    func testABuddyReadsThePaneIdItWasPrintedUnder() throws {
        let json = #"""
        {"handle":"kay","paneId":"w1:p1","status":"live","repo":null,"branch":null,"title":null,"unread":2,"mentions":0}
        """#
        let buddy = try JSONDecoder().decode(ChatBuddy.self, from: Data(json.utf8))
        XCTAssertEqual(buddy.paneID, "w1:p1")
        XCTAssertEqual(buddy.unread, 2)
        XCTAssertNil(buddy.repo)
    }

    func testABroadcastResultReadsItsPaneIdAndDeliveredWord() throws {
        let json = #"{"paneId":"w1:p1","ok":true,"delivered":"queued","error":null}"#
        let result = try JSONDecoder().decode(ChatBroadcastResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.paneID, "w1:p1")
        XCTAssertEqual(result.delivered, "queued")
    }
}
```

- [ ] **Step 2: Run them and watch them fail on assertions**

Add the types with the right fields but a `decode` that always throws, so the
first run fails on `testASuccessfulRunDecodesItsShape`'s assertion rather than
on compilation.

- [ ] **Step 3: Implement the shapes**

Each shape is a `Decodable` struct with `CodingKeys` only where the wire name
differs (`paneId` to `paneID`). Write every one from the contract table above.
`ChatSent` deliberately has no `ok` field: it is always true and is not a
discriminator, so decoding it would invite a branch on it.

- [ ] **Step 4: Implement `ChatOutcome`**

```swift
public struct ChatFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// One run's answer. The far side prints its failure as `{"error":"..."}` on
/// STDOUT with a non-zero exit, so stdout is read either way and the exit code
/// only says which shape to expect.
public enum ChatOutcome {
    private struct Envelope: Decodable { let error: String }

    public static func decode<T: Decodable>(
        _ type: T.Type, stdout: Data, exitCode: Int32
    ) throws -> T {
        if exitCode != 0 {
            let message = (try? JSONDecoder().decode(Envelope.self, from: stdout))?.error
            throw ChatFailure(message: message ?? "chat exited \(exitCode)")
        }
        return try JSONDecoder().decode(type, from: stdout)
    }
}
```

- [ ] **Step 5: Run the tests, then prove one can fail**

Expected: PASS. Then change `if exitCode != 0` to `if false`, watch
`testAFailureIsReadFromStdoutAndCarriesItsMessage` go red, and restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlockCore/Chat Tests/FlockCoreTests/ChatShapesTests.swift Tests/FlockCoreTests/ChatOutcomeTests.swift
git commit -m "chat: the wire shapes, and what one run answered"
```

---

### Task 3: Where the binary is, and whether chat exists at all

**Files:**
- Create: `Sources/FlockCore/Chat/ChatAvailability.swift`, `Sources/Flock/Chat/ChatToolLocator.swift`
- Test: `Tests/FlockCoreTests/ChatAvailabilityTests.swift`, `Tests/FlockChromeRender/ChatToolLocatorTests.swift`

**Interfaces:**
- Produces:
  - `ChatAvailability.resolve(environmentOverride:candidates:) -> String?` (pure)
  - `ChatToolLocator.binaryPath: String?` (resolved once, off the main actor)

**The resolution order**, first hit wins:

1. `FLOCK_HERDR_CHAT_BIN` if set and pointing at an executable file.
2. `~/.config/herdr/plugins/*/m4ttstack.chat*/target/release/herdr-chat`, newest
   modification time if several match.
3. Absent.

Two installs exist on this machine (`config/m4ttstack.chat` and
`github/m4ttstack.chat-3fdefc4d82ce`), which is why the glob has two wildcards.
**That directory shape is evidence, not a documented contract**: if you can find
herdr's plugin installer saying otherwise, follow it and say so in your report.

- [ ] **Step 1: Write the failing test for the pure rule**

```swift
final class ChatAvailabilityTests: XCTestCase {
    func testAnOverrideWinsOverEveryCandidate() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: "/opt/chat", candidates: [("/a", 5), ("/b", 9)]),
            "/opt/chat"
        )
    }

    /// Two installs of the same plugin are normal here, and the one built most
    /// recently is the one the user last asked for.
    func testTheNewestCandidateWins() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: nil, candidates: [("/a", 5), ("/b", 9), ("/c", 1)]),
            "/b"
        )
    }

    /// Absent is a first-class answer, not an error to report.
    func testNoOverrideAndNoCandidatesIsAbsent() {
        XCTAssertNil(ChatAvailability.resolve(environmentOverride: nil, candidates: []))
    }

    /// An empty override is a variable someone unset badly, not a path.
    func testAnEmptyOverrideIsIgnored() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: "", candidates: [("/a", 5)]),
            "/a"
        )
    }
}
```

- [ ] **Step 2: Run and watch it fail**, with a stub returning `nil`.

- [ ] **Step 3: Implement the pure rule**

```swift
/// Whether this machine has the chat plugin at all, decided from paths rather
/// than from a failed call. Code past this point knows the binary exists, so a
/// failure there is a real failure worth showing the user.
public enum ChatAvailability {
    public static func resolve(
        environmentOverride: String?, candidates: [(path: String, modified: TimeInterval)]
    ) -> String? {
        if let override = environmentOverride, !override.isEmpty { return override }
        return candidates.max { $0.modified < $1.modified }?.path
    }
}
```

- [ ] **Step 4: Write `ChatToolLocator`**

It globs the two wildcards, checks each candidate is an executable regular file,
reads modification dates, and calls `ChatAvailability.resolve`. It is a `static
let` resolved once, the way `ToolPath.resolved` is, and read off the main actor.
Read `Sources/Flock/Environment/ToolPath.swift` first and match its shape,
including its logging.

Its test lives in `FlockChromeRender` (which can touch the filesystem): build a
temporary directory tree matching the glob, point the locator at it, and assert
which path it picks. **Do not test against the real `~/.config/herdr`.**

- [ ] **Step 5: Run everything, then commit**

```bash
git add Sources/FlockCore/Chat/ChatAvailability.swift Sources/Flock/Chat/ChatToolLocator.swift Tests/FlockCoreTests/ChatAvailabilityTests.swift Tests/FlockChromeRender/ChatToolLocatorTests.swift
git commit -m "chat: absent is a path question, answered once"
```

---

### Task 4: Running a verb, with a deadline

**Files:**
- Create: `Sources/Flock/Chat/ChatRunner.swift`
- Test: `Tests/FlockChromeRender/ChatRunnerTests.swift`

**Interfaces:**
- Consumes: `ChatVerb`, `ChatOutcome`, `ChatToolLocator`
- Produces:
  - `protocol ChatRunning: Sendable { func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) }`
  - `ChatRunner: ChatRunning`, and `ChatRunner.deadline: Duration` (5 seconds)

The protocol is what every later task writes against, so views and stores are
testable with a fake that returns canned JSON.

- [ ] **Step 1: Write the failing test**

Test `ChatRunner` against a real process, but never against `herdr-chat`: use
`/bin/echo` and `/bin/sleep` as stand-ins, which prove the two things that
matter. A test that runs the real binary would contact `rt`.

```swift
final class ChatRunnerTests: XCTestCase {
    func testItReadsStdoutAndTheExitCode() async throws {
        let runner = ChatRunner(binaryPath: "/bin/echo", deadline: .seconds(5))
        let out = try await runner.runRaw(["hello"])
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .newlines), "hello")
        XCTAssertEqual(out.exitCode, 0)
    }

    /// A hung rt daemon must fail the call rather than leave a spinner up
    /// forever, and the child must not outlive the deadline either.
    func testACallThatOverrunsItsDeadlineFailsAndKillsTheChild() async {
        let runner = ChatRunner(binaryPath: "/bin/sleep", deadline: .milliseconds(200))
        let started = Date()
        do {
            _ = try await runner.runRaw(["10"])
            XCTFail("a call past its deadline must throw")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline did not fire")
        }
    }
}
```

- [ ] **Step 2: Run and watch both fail.**

- [ ] **Step 3: Implement**

`Process` with `standardOutput` a `Pipe`, run off the main actor, with a task
that terminates the child when the deadline elapses. Throw `ChatFailure` with a
message naming the timeout so the toast can say what happened.

- [ ] **Step 4: Run the tests, then commit**

```bash
git add Sources/Flock/Chat/ChatRunner.swift Tests/FlockChromeRender/ChatRunnerTests.swift
git commit -m "chat: a verb runs with a deadline, and its child dies with it"
```

---

### Task 5: What a status means for the popover

**Files:**
- Create: `Sources/FlockCore/Chat/ChatPresence.swift`
- Test: `Tests/FlockCoreTests/ChatPresenceTests.swift`

**Interfaces:**
- Consumes: `ChatStatus`
- Produces: `ChatPresence.buttons(for:) -> (signIn: ButtonState, signOut: ButtonState)`
  with `enum ButtonState { case primary, secondary }`, and
  `ChatPresence.canSend(_ status: ChatStatus?) -> Bool`

The rule, from the designs (`popover-signed-out.png`, `popover-signed-in.png`):
the button that applies is primary, the other is secondary and never hidden, so
the pair reads as a state rather than as a changing menu. Sending needs a signed
in pane.

- [ ] **Step 1: Write the failing tests**

```swift
final class ChatPresenceTests: XCTestCase {
    private func status(signedIn: Bool) -> ChatStatus {
        ChatStatus(handle: signedIn ? "kay" : nil, state: signedIn ? "live" : "not signed in",
                   pane: "w1:p1", signedIn: signedIn, rooms: signedIn ? ["#rt"] : [])
    }

    func testSignInLeadsWhenThePaneIsNotSignedIn() {
        let buttons = ChatPresence.buttons(for: status(signedIn: false))
        XCTAssertEqual(buttons.signIn, .primary)
        XCTAssertEqual(buttons.signOut, .secondary)
    }

    func testSignOutLeadsOnceThePaneIsSignedIn() {
        let buttons = ChatPresence.buttons(for: status(signedIn: true))
        XCTAssertEqual(buttons.signOut, .primary)
        XCTAssertEqual(buttons.signIn, .secondary)
    }

    /// A pane that is not signed in cannot send, and the compose footer says
    /// why rather than letting the user type and then fail.
    func testSendingNeedsASignedInPane() {
        XCTAssertFalse(ChatPresence.canSend(status(signedIn: false)))
        XCTAssertTrue(ChatPresence.canSend(status(signedIn: true)))
    }

    /// No status yet is not the same as signed out, but it is equally unable
    /// to send.
    func testAnUnknownStatusCannotSend() {
        XCTAssertFalse(ChatPresence.canSend(nil))
    }
}
```

- [ ] **Steps 2 to 4:** stub, watch red, implement, green, commit.

```bash
git commit -m "chat: the button that applies leads, and the other stays visible"
```

---

### Task 6: The store

**Files:**
- Create: `Sources/Flock/Chat/ChatStore.swift`
- Modify: `Sources/Flock/FlockApp.swift` (construct it, put it in the environment)
- Test: `Tests/FlockChromeRender/ChatStoreTests.swift`

**Interfaces:**
- Consumes: `ChatRunning`, `ChatVerb`, `ChatOutcome`, the shapes
- Produces: `@Observable final class ChatStore` with
  - `var isAvailable: Bool`
  - `func status(for pane: PaneID) -> ChatStatus?` (cached per pane)
  - `func refreshStatus(for:) async`, `func signIn(_:) async`, `func signOut(_:) async`
  - `func peek() async -> ChatPeek?`, `func targets() async -> ChatTargets?`
  - `func quickSend(to:body:) async -> Bool`
  - `func broadcast(panes:body:) async -> ChatBroadcast?`
  - `func jump(handle:) async -> ChatJump?`, `func viewerURL(room:) async -> URL?`

Follow `ThemeStore` and `TerminalTextSizeStore` for the injection shape: the
runner is a constructor parameter so tests pass a fake.

Failures raise a toast through `ToastCenter` and return nil or false; they never
throw into a view.

- [ ] **Step 1: Write the failing tests** with a fake runner returning canned
  JSON, covering: a successful status caches; a failure raises a toast and
  leaves the cache alone; `isAvailable` is false when the locator found nothing
  and no verb is ever run in that state.

- [ ] **Steps 2 to 5:** stub, red, implement, green, commit.

```bash
git commit -m "chat: one store, per-pane status, failures as toasts"
```

---

### Task 7: The chat button in a pane's chrome

**Files:**
- Modify: `Sources/Flock/Views/PaneCellView.swift`
- Create: `Sources/FlockCore/Chat/ChatButtonModel.swift`
- Test: `Tests/FlockCoreTests/ChatButtonModelTests.swift`, plus a render test in
  `Tests/FlockChromeRender/ChromeRenderTests.swift`

Design: `trigger-and-placement.png`. The button sits in the pane's top chrome,
left of the agent status dot, and is both the trigger and the state:

- **signed in:** the pane's chat handle, a divider, the chat glyph, the unread
  count; accent-bordered
- **signed out:** the chat glyph alone, muted, no border
- **no chat binary:** no button at all

- [ ] **Step 1:** Write `ChatButtonModel.appearance(availability:status:unread:)`
  returning an enum of those three cases, and test all three plus the boundary
  (available but status not yet loaded reads as signed out, not as absent).

- [ ] **Steps 2 to 4:** red, implement, green.

- [ ] **Step 5:** Add the button to `PaneCellView`'s chrome row, beside
  `statusChip`. Add a chrome render test asserting the button is drawn for a
  signed-in pane and absent when chat is unavailable.

- [ ] **Step 6: Commit**

```bash
git commit -m "pane: a chat button that is also the unread badge"
```

---

### Task 8: The popover, which is the launcher

**Files:**
- Create: `Sources/Flock/Chat/ChatPopover.swift`
- Modify: `Sources/Flock/Views/PaneCellView.swift` (present it from the button)
- Test: render tests for both states

Designs: `popover-signed-out.png`, `popover-signed-in.png`.

Structure, top to bottom:
- **Status block:** dot, handle, state word, a chip naming the pane it acts on,
  rooms below. The state word is rt's own vocabulary, printed as given.
- **Features:** Broadcast to panes, Chat peek, Quick send, Open viewer, each
  with its shortcut.
- **This pane:** Sign in and Sign out as buttons, per `ChatPresence`.

Selecting a feature replaces the popover's content with a back chevron; Open
viewer closes the popover and opens the URL. The popover is anchored to the
button, right-aligned, and closes on click-away or Esc.

**Esc must not reach the pane.** flock already learned this one: the Esc that
leaves rearrange mode was also forwarded to the pane and interrupted a live
agent. Read `Sources/Flock/Drag/RearrangeMode.swift` and
`Sources/FlockCore/Drag/RearrangeModeMachine.swift`'s `handleEscape` for the
shape, and make the popover's Esc consume itself the same way.

- [ ] Steps: build the view, render-test both states, then commit.

```bash
git commit -m "chat: a popover that is the launcher, anchored to its pane"
```

---

### Task 9: Peek, quick send, broadcast

**Files:**
- Create: `Sources/Flock/Chat/ChatPeekView.swift`, `ChatQuickSendView.swift`, `ChatBroadcastView.swift`
- Create: `Sources/FlockCore/Chat/ChatBroadcastSummary.swift`
- Test: `Tests/FlockCoreTests/ChatBroadcastSummaryTests.swift`, render tests for each view

Designs: `peek.png`, `quick-send.png`, `broadcast.png`.

- **Peek:** buddies with status dot, handle, where, unread, and a jump
  affordance; rooms with unread below. Clicking a buddy row calls `jump` and
  then focuses that workspace, tab and pane **from flock's own model**, using
  the returned `paneId`. The verb deliberately moves nothing.
- **Quick send:** targets as chips from `targets` (rooms then people, prefixes
  intact), a message field, and a send button. The footer names the handle the
  message sends as, and sending is disabled when `ChatPresence.canSend` is false.
- **Broadcast:** the pane list with checkboxes and select-all, the message, and a
  send button. Panes that are not signed in cannot be selected.

`ChatBroadcastSummary` is the pure rule for what the toast says afterwards, and
it is where rule 4 and rule 5 from the contract live:

```swift
/// What a fan-out is worth telling the user. `delivered` is rt's own word and
/// only "refused" is a failure: a queued message is one rt has taken
/// responsibility for, so reporting it as failed sends the user chasing a
/// message that arrived.
public enum ChatBroadcastSummary {
    public static func message(for broadcast: ChatBroadcast) -> String?
}
```

- [ ] Test it with: every pane accepted (no toast), one queued and one accepted
  (no toast), one refused among three (a toast naming the refused pane), and
  every pane refused (a toast saying so). Watch each fail first.

- [ ] Build the three views, render-test each, and commit each separately.

---

### Task 10: The Chat menu, and degrading when mattstack is not there

**Files:**
- Create: `Sources/Flock/Chat/ChatCommands.swift`
- Modify: `Sources/Flock/FlockApp.swift` (add the command group)
- Test: `Tests/FlockCoreTests/ChatDegradationTests.swift`

Design: `menu-bar.png`. Every action with its shortcut; Sign Out dimmed when the
focused pane is not signed in, Sign In when it is; **the whole menu absent when
the binary is.**

The spec's degradation table is the test matrix, one test per row:

| Missing | What flock does |
| --- | --- |
| `herdr-chat` binary | no chat button, no Chat menu, nothing greyed out, no dialogue |
| `rt` binary | the same: chat is absent, not broken |
| `rt` daemon not running | chat UI present, every verb fails, the popover says so in one line with a Retry, and nothing tries to start the daemon |
| `deck` | Open viewer alone is disabled with its own reason; everything else works |
| signed out of chat | not a failure: Sign in leads, sends are disabled with the footer saying why |

Two rules the tests must hold, beyond the table:

- **A verb that never answers fails on its deadline** rather than hanging. Drive
  it with a fake runner that never returns.
- **"Chat is absent" and "chat is broken" can never collapse into each other.**
  A test for each, asserting the UI differs.

- [ ] Steps: write the matrix as tests first, watch each fail, then build the
  menu and whatever the rows demand, then commit.

```bash
git commit -m "chat: absent on a machine without mattstack, broken only when it is"
```

---

## What this plan does not do

- **No chat reading.** The viewer does that, and the plugin hands off to it.
  flock is not getting a message stream.
- **No chat sidebar.** The popover acts on one pane and its actions are
  momentary.
- **No notifications.** flock's attention toasts are about agent status; chat
  unread shows on the pane button and in peek.
- **No bundling of `herdr-chat`.** Resolution finds an installed plugin;
  shipping one is a later decision.
