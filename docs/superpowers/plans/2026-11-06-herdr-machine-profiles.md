# herdr machine profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every enabled herdr saved machine shows up as a Flock profile whose session runs over an SSH socket forward that Flock owns, with a sidebar picker to switch.

**Architecture:** A machine profile's socket path is the local end of an `ssh -N -L … -L …` forward that Flock runs for that session's lifetime. Everything that reads a socket (store, bridges, subscribers) runs unchanged; `HerdrStore`'s reconnect loop covers the time before the forward answers. Machine-specific behavior hangs off one value, `FlockProfile.machine`, and one session flag, `isRemoteMachine`.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest, xcodegen, OpenSSH client.

**Spec:** `docs/superpowers/specs/2026-11-06-herdr-machine-profiles-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host, ticket id. Fixtures use `acme`; machine fixtures use label `acme-mini`, target `acme-mini`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them). Comments state constraints only.
- Tests are hermetic: no test spawns ssh, herdr, herdr-chat, deck or rt, or touches the network. Every process sits behind an injected closure or protocol.
- Child processes get `ToolPath.childEnvironment()` (needs `SSH_AUTH_SOCK` and PATH from the login shell).
- Unix socket paths at most 104 bytes. Tunnel dir shape: `/tmp/flock-<uid>/<bundle tag>-<first 12 chars of machine id>/`, mode 0700, holding `herdr.sock` and `herdr-client.sock`.
- ssh options, verbatim: `-N -o BatchMode=yes -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3`.
- Never start a server for a machine profile; never fall back to Default's socket while a machine profile is current.
- Run `xcodegen` after adding files; run `Scripts/checks.sh` after `git add`.
- Test runs: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/<Class> -skipPackagePluginValidation -derivedDataPath <scratch>/dd` (scratch = the session scratchpad). Run only the classes you touch.
- UI tasks render dark and light with `TEST_RUNNER_FLOCK_<AREA>_RENDER_DIR=<dir>` and the PNGs are looked at before the task is done.

## Review Focus

1. **Relaunch onto an unreachable machine:** Flock quit on mini, mini is off at launch. Expect "Can't reach acme-mini." and zero panes, never this Mac's panes. Test in Task 4 (supervisor) and Task 1 (store keeps a stored machine profile current with no list read yet).
2. **ssh exits mid-session** (sleep, Wi-Fi drop): expect the banner to go to unreachable, ssh to restart with backoff, panes to come back on their own. Test in Task 4.
3. **Machine renamed or removed in herdr while current:** expect the session to keep running; rename updates the label; removal takes effect only after switching away. Test in Task 1.
4. **Both Flock apps on the same machine:** expect separate tunnel dirs and the existing "Quit the other / Stay / Keep both" prompt keyed by machine id. Test in Task 2 (attach key) and Task 3 (paths differ by bundle tag).
5. **Pasting a screenshot while the upload fails** (mini dropped): expect a short notice and no local path pasted. Test in Task 8.

---

### Task 1: Machine model, list parsing, store sync

**Files:**
- Create: `Sources/FlockCore/Profiles/HerdrMachine.swift`
- Modify: `Sources/FlockCore/Profiles/FlockProfile.swift`, `Sources/FlockCore/Profiles/ProfileStore.swift`
- Test: `Tests/FlockCoreTests/HerdrMachineTests.swift`, `Tests/FlockCoreTests/ProfileStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct HerdrMachine: Codable, Equatable, Sendable { id: String; label: String; target: String; session: String }`
  - `public enum HerdrMachineList { static func parse(_ stdout: Data) -> [HerdrMachine]? }` (enabled entries only; nil when not that JSON array)
  - `FlockProfile.machine: HerdrMachine?` (decodes as nil when absent, so stored profiles load unchanged); `var isMachine: Bool`
  - `ProfileStore.init(..., machineSocketPath: @escaping (HerdrMachine) -> String = { _ in "" })`
  - `ProfileStore.syncMachines(_ machines: [HerdrMachine])`
  - `ProfileStore.socketPath(of:)` returns `machineSocketPath(machine)` for machine profiles
  - Machine profile id: `"machine.\(machine.id)"`

- [ ] **Step 1: Write the failing tests**

```swift
// HerdrMachineTests
func testParseKeepsEnabledMachinesOnly() {
    let json = #"[{"id":"0123456789abcdef0123456789abcdef","label":"acme-mini","target":"acme-mini","session":"default","enabled":true,"selected":false},{"id":"fedcba9876543210fedcba9876543210","label":"off","target":"off","session":"default","enabled":false,"selected":false}]"#
    XCTAssertEqual(HerdrMachineList.parse(Data(json.utf8)),
        [HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")])
}
func testParseRejectsOtherOutput() { XCTAssertNil(HerdrMachineList.parse(Data("nope".utf8))) }

// ProfileStoreTests
func testSyncAddsMachineProfilesAfterUserProfiles()      // order: Default, user profiles, machines; name == label; id == "machine.<id>"
func testSyncRenamesInPlaceAndKeepsID()                  // label "acme-mini" -> "acme-mac": same id, new name
func testSyncDropsRemovedMachineUnlessCurrent()          // current machine survives a sync without it; dropped after select(default) + sync
func testStoredMachineStaysCurrentBeforeAnySync()        // relaunch: currentID "machine.<id>" restored with no sync call
func testMachineSocketPathComesFromInjectedClosure()     // socketPath(of:) == "/tmp/flock-501/dev-0123456789ab/herdr.sock"
func testMachineProfilesCannotBeRenamedOrDeleted()       // rename no-op, delete returns false
func testProfilesStoredBeforeMachinesStillDecode()       // old JSON without "machine" key loads
```

- [ ] **Step 2: Run, expect FAIL** (`-only-testing:FlockCoreTests/HerdrMachineTests -only-testing:FlockCoreTests/ProfileStoreTests`): types undefined.
- [ ] **Step 3: Implement.** Machine profiles persist with the rest (that is what makes relaunch work without a list read). `syncMachines` upserts by machine id and removes absent ones except `currentID`. `rename`/`delete`/`setSocket` ignore machine profiles. `knownSockets` for a machine profile is `[]`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `profiles: herdr machines as derived profiles`

### Task 2: Suites, attach key, child socket

**Files:**
- Modify: `Sources/FlockCore/Profiles/ProfileSuites.swift`, `Sources/FlockCore/Profiles/ProfileSessionController.swift`, `Sources/Flock/Environment/ToolPath.swift`, `Sources/Flock/FlockApp.swift` (closures only)
- Test: `Tests/FlockCoreTests/ProfileSuitesTests.swift`, `Tests/FlockCoreTests/ProfileSessionControllerTests.swift`

**Interfaces:**
- Consumes: `FlockProfile.machine`, `ProfileStore.socketPath(of:)` (Task 1)
- Produces:
  - `ProfileSuites.preferencesSuiteName(bundleID: String, profile: FlockProfile) -> String?` (replaces the `profileID:` form; nil for Default and for every machine profile)
  - `ProfileSuites.attachKey(for profile: FlockProfile, socketPath: String) -> String` = `"herdr-machine:\(machine.id)"` for machines, else `socketPath`
  - `ProfileSessionEnvironment.setChildSocket: (String?) -> Void`; controller passes nil when the profile is a machine
  - `confirmAttach` and `register` receive the attach key, not the socket
  - `ToolPath.setHerdrSocket(_ socketPath: String?)` (nil clears it)
  - `ProfileSessionContext.isRemoteMachine: Bool` (`profile.machine != nil`)

- [ ] **Step 1: Write the failing tests**

```swift
func testMachineProfileSharesDefaultPreferences() {
    XCTAssertNil(ProfileSuites.preferencesSuiteName(bundleID: "b", profile: machineProfile))
}
func testMachineAttachKeyIsMachineID() {
    XCTAssertEqual(ProfileSuites.attachKey(for: machineProfile, socketPath: "/tmp/flock-501/dev-0123456789ab/herdr.sock"),
                   "herdr-machine:0123456789abcdef0123456789abcdef")
}
// ProfileSessionControllerTests
func testSwitchToMachineClearsChildSocketAndConfirmsByMachineKey()  // setChildSocket got nil; confirmAttach got "herdr-machine:<id>"
func testMachineIdStateIsItsOwnSuite()                              // idState suite != nil and != Default's
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Update `FlockApp`'s `confirmAttach`/`register`/`settle` call sites to the key; `FlockClientGuard` treats the key as an opaque string already.
- [ ] **Step 4: Run, expect PASS** (`ProfileSuitesTests`, `ProfileSessionControllerTests`, `ProfileStoreTests`).
- [ ] **Step 5: Commit** `profiles: machine profiles share Default's settings, attach by machine id`

### Task 3: Tunnel paths and ssh commands

**Files:**
- Create: `Sources/FlockCore/Machines/MachineTunnelPaths.swift`, `Sources/FlockCore/Machines/MachineSSH.swift`
- Test: `Tests/FlockCoreTests/MachineTunnelPathsTests.swift`, `Tests/FlockCoreTests/MachineSSHTests.swift`

**Interfaces:**
- Consumes: `HerdrMachine`, `HerdrSessionList.parse` (existing)
- Produces:
  - `MachineTunnelPaths(uid: uid_t, bundleTag: String, machineID: String)` with `directory`, `apiSocket`, `clientSocket: String`; `static func bundleTag(for bundleID: String) -> String` (`"rel"` for the release id, `"dev"` for any id ending `.dev`, else first 8 hex of SHA-256)
  - `MachineSSH.resolveArguments(target: String) -> [String]` (ssh args that run the remote herdr's `session list --json`)
  - `MachineSSH.remoteAPISocket(from entries: [HerdrSessionEntry], session: String) -> String?` (`session == "default"` matches `isDefault`)
  - `MachineSSH.remoteClientSocket(apiSocket: String) -> String` (sibling `herdr-client.sock`)
  - `MachineSSH.forwardArguments(target: String, paths: MachineTunnelPaths, remoteAPISocket: String) -> [String]`
  - `MachineSSH.uploadArguments(target: String, remotePath: String) -> [String]`, `MachineSSH.remotePasteDirectory = "/tmp/flock-paste"`

- [ ] **Step 1: Write the failing tests**

```swift
func testPathsFitTheSocketLimitAndDifferByApp() {
    let dev = MachineTunnelPaths(uid: 501, bundleTag: "dev", machineID: "0123456789abcdef0123456789abcdef")
    let rel = MachineTunnelPaths(uid: 501, bundleTag: "rel", machineID: "0123456789abcdef0123456789abcdef")
    XCTAssertEqual(dev.apiSocket, "/tmp/flock-501/dev-0123456789ab/herdr.sock")
    XCTAssertEqual(dev.clientSocket, "/tmp/flock-501/dev-0123456789ab/herdr-client.sock")
    XCTAssertNotEqual(dev.directory, rel.directory)
    XCTAssertLessThanOrEqual(dev.clientSocket.utf8.count, 104)
}
func testForwardArgumentsCarryBothSocketsAndTheFixedOptions() {
    let args = MachineSSH.forwardArguments(target: "acme-mini", paths: dev,
        remoteAPISocket: "/Users/acme/.config/herdr/herdr.sock")
    XCTAssertEqual(Array(args.prefix(11)), ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
    XCTAssertTrue(args.contains("/tmp/flock-501/dev-0123456789ab/herdr.sock:/Users/acme/.config/herdr/herdr.sock"))
    XCTAssertTrue(args.contains("/tmp/flock-501/dev-0123456789ab/herdr-client.sock:/Users/acme/.config/herdr/herdr-client.sock"))
    XCTAssertEqual(args.last, "acme-mini")
}
func testResolveScriptFallsBackToLocalBin()     // the remote command string contains "command -v herdr" and "$HOME/.local/bin/herdr"
func testRemoteSocketPicksNamedOrDefaultSession()
func testUploadArgumentsWriteIntoPasteDirectory() // remote command: mkdir -p /tmp/flock-paste && cat > '<quoted path>'
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Remote command strings are single-quoted with the same quoting rule herdr's `shell_quote` uses.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `machines: tunnel paths and ssh argument builders`

### Task 4: Tunnel supervisor

**Files:**
- Create: `Sources/FlockCore/Machines/MachineTunnel.swift`
- Test: `Tests/FlockCoreTests/MachineTunnelTests.swift`

**Interfaces:**
- Consumes: `MachineTunnelPaths`, `MachineSSH` (Task 3)
- Produces:
  - `public enum MachineTunnelState: Equatable { case connecting, up, unreachable(reason: String), noServer, stopped }`
  - `public protocol MachineTunnelChild: AnyObject { var exited: AsyncStream<String> { get }; func terminate() }` (the stream yields ssh's last stderr line once, on exit)
  - `@MainActor @Observable public final class MachineTunnel` with
    `init(machine: HerdrMachine, paths: MachineTunnelPaths, resolve: @escaping (HerdrMachine) async throws -> String, launch: @escaping ([String]) throws -> MachineTunnelChild, probe: @escaping (String) async -> Bool, prepareDirectory: @escaping (String) throws -> Void, removeDirectory: @escaping (String) -> Void, backoff: @escaping (Int) -> Duration = MachineTunnel.defaultBackoff)`,
    `private(set) var state: MachineTunnelState`, `func start()`, `func stop() async`
  - `static func defaultBackoff(_ attempt: Int) -> Duration` = 1, 2, 4, 8, 15, then 15 s
  - Resolve errors whose message reports no running server map to `.noServer`; every other failure to `.unreachable(reason:)`. Resolved remote socket cached per instance; dropped and re-resolved once after a forward exit that happens before `probe` ever succeeded.

- [ ] **Step 1: Write the failing tests** (fake child, fake clock via injected backoff of `.zero`)

```swift
func testStartResolvesLaunchesAndGoesUpWhenProbeAnswers()
func testSshExitMovesToUnreachableWithStderrThenRestarts()   // state .unreachable("Connection refused"), launch called twice
func testResolveFailureIsUnreachableAndNeverLaunches()       // Review Focus 1
func testNoRemoteServerIsNoServerState()
func testStopTerminatesChildRemovesDirectoryAndStaysStopped() // no restart after stop
func testEarlyExitReResolvesOnce()                            // resolve called twice, not three times
func testBackoffSchedule() { XCTAssertEqual((1...7).map(MachineTunnel.defaultBackoff), [1,2,4,8,15,15,15].map { .seconds($0) }) }
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `machines: tunnel supervisor`

### Task 5: App wiring

**Files:**
- Create: `Sources/Flock/Machines/SSHTunnelProcess.swift` (`MachineTunnelChild` over `Process`, ssh at `/usr/bin/ssh`, env from `ToolPath.childEnvironment()`), `Sources/Flock/Machines/MachineSources.swift` (`list() async -> [HerdrMachine]?` via `herdr machine list --json` with `ToolRunner`, 5 s; `resolve(_:) async throws -> String` via ssh + `HerdrSessionList.parse` + `MachineSSH.remoteAPISocket`; `probe(_:)` = a `LineSocket` connect; `sweepStaleDirectories(bundleTag:)`)
- Modify: `Sources/Flock/Environment/FlockSession.swift`, `Sources/Flock/FlockApp.swift`, `project.yml` only if a new group needs it

**Interfaces:**
- Consumes: Tasks 1 to 4
- Produces: `FlockSession.machineTunnel: MachineTunnel?` (non-nil exactly when `context.isRemoteMachine`), `FlockSession.isRemoteMachine: Bool`

- [ ] **Step 1: Wire it.** `ProfileStore` gets `machineSocketPath: { MachineTunnelPaths(uid: getuid(), bundleTag: …, machineID: $0.id).apiSocket }`. `FlockSession.start()` starts the tunnel then the store (the store's reconnect loop absorbs the gap); `shutdown()` runs the existing teardown, then `await machineTunnel?.stop()`. At launch: sweep this bundle's stale tunnel dirs, then `profiles.syncMachines(await MachineSources.list() ?? [])` off the first frame (a nil list changes nothing). `startTarget` returns nil for machine profiles.
- [ ] **Step 2: Build.** `xcodebuild build -scheme Flock-dev -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath <scratch>/dd` succeeds.
- [ ] **Step 3: Run Task 1 to 4 test classes, expect PASS.**
- [ ] **Step 4: Commit** `machines: run the tunnel for machine profile sessions`
- [ ] **Step 5: Hand-check.** `Scripts/dev-build.sh`; ask Matt to restart Flock Dev, switch to the machine profile (Flock > Profile until Task 9 lands) and confirm panes load. Note: Matt's hand-made spike profile and the spike tunnel are separate and can stay.

### Task 6: Connection banner copy and version warning

**Files:**
- Create: `Sources/FlockCore/Machines/MachineConnectionCopy.swift`
- Modify: the connection banner in `Sources/Flock/Views/MainWindow.swift` (around the `connectionState` switch at line 529) and its text source
- Test: `Tests/FlockCoreTests/MachineConnectionCopyTests.swift`, `Tests/FlockChromeRender` (existing banner render, add machine states)

**Interfaces:**
- Consumes: `MachineTunnelState`, `HerdrModel.herdrVersion`
- Produces: `MachineConnectionCopy.banner(label: String, tunnel: MachineTunnelState, store: HerdrConnectionState) -> String?`, `MachineConnectionCopy.versionWarning(label: String, local: String?, remote: String?) -> String?`

- [ ] **Step 1: Write the failing tests** with the spec's exact copy:

```swift
XCTAssertEqual(MachineConnectionCopy.banner(label: "acme-mini", tunnel: .connecting, store: .connecting), "Connecting to acme-mini…")
XCTAssertEqual(MachineConnectionCopy.banner(label: "acme-mini", tunnel: .unreachable(reason: "Permission denied (publickey)."), store: .reconnecting(attempt: 1)),
    "Can't reach acme-mini. Permission denied (publickey). If your key has a passphrase, run ssh-add, then check that ssh acme-mini works.")
XCTAssertEqual(MachineConnectionCopy.banner(label: "acme-mini", tunnel: .noServer, store: .notRunning(attempt: 1)), "herdr isn't running on acme-mini.")
XCTAssertNil(MachineConnectionCopy.banner(label: "acme-mini", tunnel: .up, store: .connected))
XCTAssertEqual(MachineConnectionCopy.versionWarning(label: "acme-mini", local: "0.9.5", remote: "0.9.6"),
    "acme-mini runs herdr 0.9.6 and this Mac has 0.9.5. Panes may misbehave until they match.")
XCTAssertNil(MachineConnectionCopy.versionWarning(label: "acme-mini", local: "0.9.5", remote: "0.9.5"))
XCTAssertEqual(MachineConnectionCopy.removed(label: "acme-mini"), "acme-mini is no longer a saved herdr machine.")
```

The removed banner shows when a non-nil machine list (launch, picker or Settings open) no longer has the current machine, with a "Switch to Default" button calling `controller.switchTo(profileID: FlockProfile.defaultID)`. `ProfileStore` exposes `var currentMachineMissing: Bool`, set by `syncMachines` (add `testSyncFlagsCurrentMachineMissing` to Task 1).

(Host-key failures get "…then add its host key to known_hosts." in place of the ssh-add sentence. Use whatever the store's connection type is actually named.)
- [ ] **Step 2: Run, expect FAIL.**  - [ ] **Step 3: Implement and wire;** no Start button for machine profiles; local version from `herdr --version` once per session.
- [ ] **Step 4: Run tests, expect PASS; render the banner dark and light and look at it.**
- [ ] **Step 5: Commit** `machines: connection banner and version warning`

### Task 7: Remote session gates

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (new init param `isRemoteMachine: Bool = false`), `Sources/FlockCore/Environment/StartingFolder.swift`, `Sources/Flock/Ghostty/GhosttyControlSurfaceFactory.swift` + `GhosttySession.swift` (`isRemoteMachine`), `Sources/Flock/FlockApp.swift` (update store, mouse patch store, server picker gating), `Sources/Flock/Views/Settings/ProfilesSettingsSection.swift`, `Sources/Flock/Views/Settings/ServersSettingsSection.swift`, `Sources/Flock/Views/Settings/StartingFolderSettingsSection.swift`
- Test: `Tests/FlockCoreTests/StartingFolderTests.swift`, `Tests/FlockCoreTests/SessionViewModel*` (whichever file covers repo branches / mission board), `Tests/FlockChromeRender` settings render

**Interfaces:**
- Consumes: `FlockSession.isRemoteMachine` (Task 5)
- Produces: `StartingFolderChoice.cwd(paneFolder:home:isRemoteMachine:) -> String?` (nil for Home and Custom when remote, so herdr opens in the machine's home; `.mainCheckout` also nil)

- [ ] **Step 1: Write the failing tests**

```swift
func testRemoteMachineSendsNoLocalStartingFolder() {
    XCTAssertNil(StartingFolderChoice(folder: .home).cwd(paneFolder: nil, home: "/Users/acme", isRemoteMachine: true))
    XCTAssertNil(StartingFolderChoice(folder: .custom, customPath: "/Users/acme/src").cwd(paneFolder: nil, home: "/Users/acme", isRemoteMachine: true))
}
func testRemoteSessionReadsNoRepoBranches()      // RepoBranchCache read closure never called for a remote view model
func testRemoteSessionLinksNoBoardCards()        // mission board matches no pane by cwd when remote
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement the gates.** Remote sessions: no repo/branch reads, no board or rt pane linking by cwd (`MissionBoard`, `RtCoordinator`), chat button unavailable, `PaneLink.file` never resolved (web links still open), herdr update and mouse patch rows hidden, Settings > Server shows "Managed by herdr machine" in place of the picker, machine rows in Settings > Profiles read-only with that note (opening the tab runs `MachineSources.list()` and `syncMachines`), Custom starting folder shows "Ignored on herdr machines."
- [ ] **Step 4: Run tests, expect PASS; render Settings dark and light and look at it.**
- [ ] **Step 5: Commit** `machines: keep local-only features off machine sessions`

### Task 8: Remote paste upload

**Files:**
- Create: `Sources/Flock/Machines/RemoteFileUploader.swift`
- Modify: `Sources/FlockCore/Ghostty/ClipboardPaste.swift`, `Sources/Flock/Ghostty/NSPasteboard+PasteText.swift`, `Sources/Flock/Ghostty/GhosttySurfaceView.swift` (`paste(_:)`), `Sources/Flock/Ghostty/GhosttyHost.swift` (`ghosttyHostReadClipboard`)
- Test: `Tests/FlockCoreTests/ClipboardPasteTests.swift`

**Interfaces:**
- Consumes: `MachineSSH.uploadArguments`, `MachineSSH.remotePasteDirectory`, `GhosttySession.isRemoteMachine`
- Produces:
  - `ClipboardPaste.remotePlan(for: [PasteboardItemDescription]) -> [RemotePasteItem]` with `enum RemotePasteItem: Equatable { case text(String), uploadFile(localPath: String), uploadImage(typeIdentifier: String, fileExtension: String), nothing }`
  - `ClipboardPaste.remotePath(fileName: String, token: String) -> String` = `"/tmp/flock-paste/\(token)-\(fileName)"`
  - `RemoteFileUploader(target: String)` with `func upload(_ data: Data, to remotePath: String) async throws`
  - `NSPasteboard.remotePasteText(uploader: RemoteFileUploader) async -> RemotePasteOutcome` (`.text(String)`, `.failed(String)`, `.nothing`)

- [ ] **Step 1: Write the failing tests**

```swift
func testRemotePlanUploadsFileURLsInsteadOfPastingLocalPaths() {
    let item = PasteboardItemDescription(fileURLPath: "/Users/acme/shot.png", string: nil, typeIdentifiers: ["public.file-url"])
    XCTAssertEqual(ClipboardPaste.remotePlan(for: [item]), [.uploadFile(localPath: "/Users/acme/shot.png")])
}
func testRemotePlanUploadsBareImageBytes()
func testRemotePlanKeepsPlainText()
func testRemotePathIsInPasteDirectory() {
    XCTAssertEqual(ClipboardPaste.remotePath(fileName: "shot.png", token: "ab12"), "/tmp/flock-paste/ab12-shot.png")
}
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Both paste entry points branch on `session.isRemoteMachine`: await `remotePasteText`, then `session.paste(text)` with the escaped remote paths. Upload is ssh with stdin = file bytes, 15 s deadline. On `.failed`, show the session's info toast "Couldn't copy that to acme-mini." and paste nothing (Review Focus 5). Local sessions are untouched.
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** `machines: paste and dropped files upload to the machine`

### Task 9: Sidebar profile picker and shortcut

**Files:**
- Create: `Sources/Flock/Views/ProfilePicker.swift`
- Modify: `Sources/Flock/Views/WorkspaceRail.swift` (top of the rail), `Sources/Flock/Menus/ProfileCommands.swift`, `Sources/Flock/FlockApp.swift`
- Test: `Tests/FlockChromeRender` (rail render with picker: Local current, acme-mini machine with its dot), `Tests/FlockCoreTests/ProfileCommandsTests` if rows logic moves

**Interfaces:**
- Consumes: `ProfileStore.profiles`, `FlockProfile.isMachine`, `MachineTunnelState` of the current session, `controller.switchTo(profileID:)`
- Produces: `ProfilePicker(profiles:currentState:switchProfile:)`; one shortcut that opens the picker's list (builder picks the key; check `Sources/Flock/Menus` and libghostty's default bindings for conflicts)

- [ ] **Step 1: Build the picker.** Current profile name at the rail's top; the list shows Default and user profiles, a divider, then machines with a small remote marker and the current one's connection dot. Opening it calls `MachineSources.list()` and `syncMachines`. The Flock > Profile menu lists machines the same way.
- [ ] **Step 2: Render dark and light** (`TEST_RUNNER_FLOCK_CHROME_RENDER_DIR`), open the PNGs, fix what reads wrong.
- [ ] **Step 3: Run `Scripts/checks.sh` after `git add`.**
- [ ] **Step 4: Commit** `machines: profile picker in the sidebar`
- [ ] **Step 5: `Scripts/dev-build.sh`** and ask Matt to try switching Local and acme-mini from the picker and the shortcut.
