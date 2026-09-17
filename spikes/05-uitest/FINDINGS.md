# Spike 05: XCUITest closed loop + headless accessibility

Two-target XcodeGen project (`SpikeApp` macOS SwiftUI app, `SpikeUITests` UI
test bundle) under `spikes/05-uitest/`. `SpikeApp` renders one draggable
rectangle (`spike.drag.source`) and one drop target (`spike.drag.target`),
using a custom `DragGesture` state machine (not system `onDrag`/NSItemProvider
drag-and-drop), matching the real app's planned drag mechanism (design spec:
"a custom in-window DragGesture state machine"). A landed drop writes the
drop point to `/tmp/spike-drop.json` and, when configured via env vars, fires
one `pane.move` request over a herdr scratch socket.

Build/regenerate: `cd spikes/05-uitest && xcodegen generate && xcodebuild
-project SpikeUITest.xcodeproj -scheme SpikeApp build -destination
'platform=macOS'`. Verified from a fully clean `DerivedData` (`rm -rf
~/Library/Developer/Xcode/DerivedData/SpikeUITest-*` first) immediately
before writing this file -- **BUILD SUCCEEDED**.

## Verdicts

| Step | Verdict | Evidence |
| --- | --- | --- |
| 1. Scripted drag (20/20) | **PASS** | `logs/step1-drag-loop.log`, `SPIKE_RESULT drags_landed=20/20` |
| 2. herdr closed loop | **PASS** (after a harness redesign -- see below) | `logs/step2-closed-loop.log` |
| 3. Headless probe (SSH to localhost) | **SKIPPED** -- precise reason below, not ambiguous | this file, "Step 3" section |

## Step 1: scripted drag, 20/20

`DragLoopUITests.testTwentyScriptedDragsLandTheDrop` drives
`source.coordinate(withNormalizedOffset:).press(forDuration: 0.3,
thenDragTo:)` in a 20-iteration loop, deleting `/tmp/spike-drop.json` before
each iteration and requiring a fresh, parseable drop file within 3s of each
drag. `ContentView.handleDrop` only writes the file when the drag's end
point actually falls inside the target's frame (read via a
`GeometryReader`/`.global`-space preference), so a coordinate-math or
gesture-wiring bug would show up as a failed landing, not a rubber-stamp
pass.

Run: `xcodebuild -project SpikeUITest.xcodeproj -scheme SpikeApp test
-destination 'platform=macOS' -only-testing:SpikeUITests/DragLoopUITests`.
Result: **20/20**, `SPIKE_RESULT drags_landed=20/20` (full log:
`logs/step1-drag-loop.log`). No Accessibility/Automation permission dialog
appeared on any of the several runs performed while building this spike
(see "Permission dialog behavior" below).

## Step 2: herdr closed loop

Gesture -> `pane.move` over herdr -> `session.snapshot` assertion, unattended
end to end -- but reaching that took two real, load-bearing discoveries about
running XCUITest against a Process()-spawned helper on macOS, both important
for Tasks 29-31.

### Finding: the macOS UI test runner is unconditionally App Sandboxed

Xcode's `xcodebuild test` wraps every macOS UI-testing bundle in an
auto-generated `<Target>-Runner.app` to host it. That wrapper carries
`com.apple.security.app-sandbox = true` **unconditionally** -- confirmed
by inspecting its live entitlements (`codesign -d --entitlements :-
SpikeUITests-Runner.app`) and by adding a custom `.entitlements` file to the
`SpikeUITests` target with `com.apple.security.app-sandbox` explicitly set to
`false`: the built `-Runner.app` entitlements were unchanged. There is no
project-level setting that turns this off; the wrapper is templated by
Apple's own toolchain, separately from whatever `CODE_SIGN_ENTITLEMENTS` is
set on the `.xctest` bundle target itself.

That sandbox is inherited by every child process the test spawns via
`Process()`. Two concrete symptoms hit while building this spike:

- `$HOME` as seen by a `Process()`-spawned `/bin/bash` resolves to the
  sandbox container (`~/Library/Containers/<bundle-id>/Data`), not the real
  home directory -- `spikes/lib/scratch-session.sh`'s
  `sock="$HOME/.config/herdr/sessions/$name/herdr.sock"` silently pointed at
  the wrong place. `getpwuid(getuid()).pw_dir` (queries opendirectoryd
  directly) is NOT subject to this virtualization and recovers the real
  path -- useful for other purposes, but does not fix the next point.
- Even pointed at the real `$HOME`, **`herdr ... server` cannot bind its
  listening socket at all from inside the sandboxed runner's child process**
  -- it fails with "server did not bind ...herdr.sock" regardless of which
  `$HOME` (real or container) it targets. The entitlements dump shows
  `com.apple.security.network.client = true` but no
  `com.apple.security.network.server` and no general filesystem-write
  exception (only a **read-only** temporary exception for `/`). Listening
  sockets need write/bind, so this tracks: the sandbox permits outbound
  client connections and reads anywhere, but not writes outside its
  container and not listening sockets.

**Consequence for Task 29:** `ScratchSession.start()` cannot spawn the herdr
server from inside the XCUITest process on macOS. The pattern that works:
start (and seed) the scratch herdr session in a plain, unsandboxed shell
*before* `xcodebuild test` runs, and have the test only **attach** to the
already-running server. Client-only operations against an existing socket
(seeding via `nc`, `session.snapshot` polling) work fine from inside the
sandboxed runner -- only the initial bind/listen is blocked. This spike's
`ScratchHerdrSession` therefore has both `start(name:)` (kept for
completeness / non-sandboxed callers) and `attach(socketPath:sessionName:)`
(what the UI test actually uses); `run-closed-loop.sh` performs the actual
`start` + `seed-layout.sh` step.

**Superseded on 2026-09-16, under Xcode 27.0.** The sentence above about
client-only operations is no longer true: the runner template changed with that
Xcode, and the sandbox now denies the bundle and its children a `connect()` to
ANY unix socket outside the container, not just `bind`. A native connect returns
EPERM and a spawned `nc -U` exits 1 silently. Loopback TCP is still permitted
(a closed port answers ECONNREFUSED rather than EPERM), and spawning a process
is still permitted, which is why the harness now reaches herdr through
`Tests/PaddockUITests/Support/bin/e2e-bridge.py`, a loopback server the wrapper
runs outside the sandbox. Measured with a throwaway probe test on this machine;
the table is in the task 29 report.

### Finding: `xcodebuild test` does not forward arbitrary env vars to the runner; `TEST_RUNNER_*` does

A plain `export FOO=bar` in the shell that invokes `xcodebuild test` never
reached `ProcessInfo.processInfo.environment` inside the XCTestCase --
consistent with `xcodebuild` curating the whole environment for the
sandboxed test-host process, not just `PATH`/`HOME`. Passing
`TEST_RUNNER_FOO=bar` as a trailing xcodebuild argument also failed (that
syntax is parsed as a build-setting override, not forwarded). What works:
`export TEST_RUNNER_FOO=bar` **in xcodebuild's own process environment**
before invoking it -- Apple's documented `TEST_RUNNER_` prefix convention,
which strips the prefix and injects the variable into the test host's
environment. `run-closed-loop.sh` uses this to pass the socket path and seed
ids (`SPIKE_SCRATCH_SOCKET`, `SPIKE_WS_ID`, `SPIKE_P1_ID`,
`SPIKE_SESSION_NAME`) into `ClosedLoopUITests`.

### Finding: `session.snapshot`'s `tabs[]` is flat, not nested per workspace

First implementation of `ScratchHerdrSession.tabCount(workspaceID:)` assumed
`result.snapshot.workspaces[].tabs[]`. The real shape (confirmed against
`spikes/03-verbs/run.sh`'s own `.result.snapshot.tabs[] | select(.tab_id==$t)`
usage) is a flat `result.snapshot.tabs[]` list where each tab object carries
its own `workspace_id`. The bug produced a false negative (test reported
`0 == 0`, tab count "unchanged," even though the raw herdr response captured
in `/tmp/spike-herdr-response.json` showed the `pane.move` had actually
succeeded and created tab `w1:t3`). Fixed by filtering the flat list on
`workspace_id`.

### Final result

`run-closed-loop.sh` (starts + seeds a scratch session in plain bash, then
runs `xcodebuild test` with `TEST_RUNNER_*` env vars set) ->
`ClosedLoopUITests.testDragFiresHerdrPaneMoveAndSnapshotSeesNewTab`: drag
lands, `HerdrBridge` fires `pane.move` with a `new_tab` destination, the
test's own independent `session.snapshot` connection observes the target
workspace's tab count grow by exactly one. **PASS** in 4.2s
(`logs/step2-closed-loop.log`). No leaked `herdr` processes or scratch
session directories afterward (checked `pgrep -fl herdr`, the container's
`.config/herdr/sessions/`, and the real `~/.config/herdr/sessions/` -- all
clean; the wrapper's `trap cleanup EXIT` ran in real, unsandboxed bash so its
`rm -rf` actually took effect, unlike an in-sandbox attempt would have).

## Step 3: headless probe (SSH to localhost) -- SKIPPED

`nc -zv localhost 22` succeeds (Remote Login/sshd is listening), so this is
not the "Remote Login is off" case the brief anticipated. What actually
blocks it: `ssh -o BatchMode=yes localhost true` fails with
`Permission denied (publickey,password,keyboard-interactive)` -- no
authorized key is configured for this account's passwordless SSH login, so a
non-interactive probe (this session cannot supply a password) cannot get a
shell at all, let alone reach the point of finding out whether the
Accessibility/Automation prompt stalls it. Provisioning an SSH key for
localhost login is an account/credential change, which is out of bounds for
this spike per the brief (only "changing Sharing settings" was named, but
adding auth material carries the same "don't reconfigure the machine to make
the probe pass" spirit, so it was left alone rather than assumed in-bounds).

**Recorded, not ambiguous:** local interactive `xcodebuild test` runs work
(steps 1 and 2, run directly from a Terminal-launched shell); whether the
same command stalls on the Accessibility/Automation permission dialog when
launched from a non-Terminal context (SSH, or headless CI) was **not
determined** by this spike, because the SSH probe itself never got a shell.
The exact command a future CI run (once localhost key auth is provisioned)
would use:

```
ssh -o BatchMode=yes localhost \
  'cd <repo>/spikes/05-uitest && xcodebuild -project SpikeUITest.xcodeproj -scheme SpikeApp test -destination "platform=macOS" -only-testing:SpikeUITests/DragLoopUITests'
```

## Permission dialog behavior

No Accessibility or Automation permission dialog appeared during any of the
roughly ten `xcodebuild test` invocations run while building this spike (the
GUI session was unlocked and the user present throughout, per the task
brief's setup). Two explanations are consistent with this: either a prior
grant already exists on this machine for Xcode/`xctest`-driven automation
(plausible, since this machine has done UI-testing work before), or macOS
26.6's `testmanagerd`-mediated automation path does not prompt per test
target the way driving an arbitrary app via the raw Accessibility API would.
This spike cannot distinguish the two without a clean-permissions VM, which
was out of scope. **Practical implication for Tasks 29-31:** do not assume a
dialog will interrupt CI-adjacent runs on a machine that has already run
Xcode UI tests once; do assume a *first-ever* run on a fresh machine may
still need one human click, and design the e2e harness bring-up (or its
onboarding doc) to say so rather than silently hang.

## Drag reliability, timing, and `launchEnvironment` notes for Tasks 29-31

- **Drag mechanism:** `DragGesture(minimumDistance: 0, coordinateSpace:
  .global)` responds correctly to XCUITest's synthesized
  `press(forDuration:thenDragTo:)` mouse events with no special-casing
  needed; 20/20 landed with no flakiness across two full runs. `.global`
  coordinate space matters -- comparing `value.location` against a target
  frame captured via `GeometryReader { $0.frame(in: .global) }` keeps both
  sides in the same space.
- **Hit-testing the drop, not just recording it:** gate the "landed" signal
  on the drop point actually falling inside the destination's frame (with a
  small inset tolerance), not on the gesture merely ending. Otherwise a
  20/20 pass rate proves nothing about coordinate accuracy.
- **`press(forDuration: 0.3, ...)`** was sufficient every time; no need was
  found for a longer press or an intermediate `moveTo` step for this simple
  two-target case. Tasks 30-31's more elaborate drags (spring-load dwell,
  edge zones) will need longer holds/dwells, but the base primitive is
  solid.
- **`XCUIApplication.launchEnvironment`** reaches the launched app process
  exactly as documented -- no surprises there. The surprises are all on the
  *test-runner's own* process environment (App Sandbox, see above), which is
  a completely separate channel from the app-under-test's environment.
- **Off-main-thread herdr calls from the app are fine:** `HerdrBridge`
  dispatches its one-shot socket round trip via
  `DispatchQueue.global(qos:.userInitiated)`; the test observes the effect
  by polling its own `session.snapshot` connection rather than assuming a
  fixed delay, and this converged in well under a second in every run.
- **One-shot connection discipline holds:** every call this spike makes to
  herdr (from the app, from the test's own client, from
  `spikes/lib/seed-layout.sh`) opens a fresh connection per request, per
  spike 02/03's established finding. Nothing here contradicts that.
- **Design the real `ScratchSession` (Task 29) around the sandbox finding
  from day one:** its `start(seeded:)` cannot itself spawn the herdr server
  if it runs from within XCTestCase code on macOS. Either (a) keep
  `ScratchSession.start` shaped as "attach to an already-running session"
  and move the actual `herdr ... server` spawn into a pre-test harness step
  (a `Makefile`/script wrapping `xcodebuild test`, analogous to
  `run-closed-loop.sh` here), or (b) if `ScratchSession.start` truly must
  run test-side, expect it to need the same `TEST_RUNNER_*` environment
  bridge for anything it needs to know that isn't derivable purely from
  files/sockets already on disk. Option (a) is what this spike validates and
  is recommended.
