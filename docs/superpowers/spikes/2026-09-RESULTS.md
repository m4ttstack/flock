# Phase 0 Spike Results Consolidation (2026-09)

## Executive summary

1. Fixtures/harness: real captures off a scratch herdr 0.8.0 session (protocol 19), no live/personal data, recapture scripts provided.
2. Socket framing: PASS, with a headline correction. herdr's api socket is one-request-per-connection; a shared connection fails after the first reply.
3. Verb matrix (mutation + split-ratio): PASS 9/9, all cases. Cross-workspace re-key rides on `pane.moved` alone; path polarity for split ratios is now mapped.
4. Observe/backfill into SwiftTerm: PASS at 1/10/30 panes, with two real caveats (cols/rows mismatch top-crops content; one emoji class is dropped).
5. XCUITest closed loop: PASS (20/20 drags, herdr round trip in 4.2s) after a sandbox-driven harness redesign; SSH headless probe SKIPPED (no key, not "Remote Login off").
6. Nested helper launch: PASS, all 3 launch paths silent, unnotarized, both clean and quarantined; recommend `NSWorkspace.openApplication`.
7. Protocol floor: MINIMUM_PROTOCOL = 22 confirmed live against herdr 0.9.0; verb matrix re-ran 9/9 on it.

## Spike 1: Fixtures and harness provenance (Tests/Fixtures/README.md)

**Verdict: PASS (provenance-clean).**

Decisive facts:
- `herdr --version`: `herdr 0.8.0`. Socket protocol: `19` (`herdr api schema --json`, `.protocol`). Schema version: `1` (`.schema_version`).
- Captured 2026-09-10 against scratch sessions only (`spikes/lib/scratch-session.sh start <name>`), never the default `~/.config/herdr/herdr.sock`.
- Three fixture files: `snapshot.json` (single-line `session.snapshot` response), `events.ndjson` (16 lines: `subscription_started`, one `seed-layout.sh` run, one `pane.move` to `new_tab`), `observe.ndjson` (38 frames: 1 `full:true` + 37 incremental, from 12 `printf` commands including ANSI red).
- Every pane in the captures ran in `/tmp` and printed only synthetic `printf` output; no live-session content, no personal data.
- Full recapture commands are recorded verbatim in the source file, including the `python3` line-flushing reader needed for `events.ndjson` (raw `nc` buffers stdout when not a tty).

Consequences for the plan:
- Fixture-driven tests anywhere in the task list are pinned to herdr 0.8.0 / protocol 19, one full minor version and 3 protocol numbers behind the 0.9.0/22 floor confirmed in Spike 7; no task number is cited in the source for this dependency, but any fixture-consuming test should note the skew.
- The recapture recipe (scratch session only, python3 flushing reader for subscriptions) is the reusable pattern for regenerating fixtures against 0.9.0 if the plan ever requires that refresh.

## Spike 2: NDJSON socket client framing (Task 11)

**Verdict: PASS on the corrected pattern; FAIL on the brief's as-specified shared-connection pattern.**

Decisive facts:
- **Headline finding: herdr's api socket is one-request-per-connection.** A second request on an already-answered connection gets `EPIPE` (errno 32); nothing ever answers it. Verified independently in Swift and in raw Python sockets.
- Brief's literal skeleton (ping + session.snapshot + 1000x pane.get on one connection): **FAIL**. Total response lines ever seen on that connection: 1 (expected 1002).
- Corrected pattern (one connection per request, concurrency 32): **PASS**. `1000 one-shot requests, concurrency 32, 1932ms total, 1.932ms/req avg`. 0 missing results, 0 parse failures, 0 id mismatches, 0 wrong pane_id.
- `events.subscribe` is single-purpose: it stays open for push events but does not accept a second request; sending anything else on it tears down the whole subscription, not just the extra write.
- Ordered delivery under burst: PASS, monotonic non-decreasing receive timestamps.
- Line size: single-tab `layout.updated` tops out around 18-20KB even at 150 splits; `session.snapshot` at 150 splits plus two seeded workspaces was **85128 bytes**, arrived as one clean unfragmented NDJSON line.
- Event propagation latency samples (ms): `16.8, 32.4, 61.8, 83.1, 94.4, 95.7, 104.7, 105.9, 110.0, 112.2, 114.0, 115.1, 118.3`, consistent with the documented 100ms server poll.
- `SO_NOSIGPIPE` + `signal(SIGPIPE, SIG_IGN)` is required: writing to a connection the peer already closed raises `SIGPIPE` on Darwin by default and kills the process.

Consequences for the plan:
- Task 11 must open one connection per request (or a small one-shot worker pool, verified safe at concurrency 32 / 1000 requests), never pool or reuse a connection for request/response traffic.
- Task 11's `events.subscribe` connection must be used for nothing but the one subscribe call plus the incoming event stream; no interleaved requests, ever.
- Task 11 needs `SO_NOSIGPIPE` (and/or process-wide `SIG_IGN` on `SIGPIPE`) on every socket fd, not as an optional hardening step.
- Task 11's line-framing buffer must not assume small messages; `session.snapshot` is the response type that reliably crosses 64KB, not per-event traffic.

## Spike 3: Mutation verb matrix + split-ratio paths (Tasks 20, 23)

**Verdict: PASS, 9/9 cases (PASS=9 FAIL=0 DIVERGED=0).**

Decisive facts:
- Case 3 (cross-workspace re-key, `w4:p3` -> `w5:p1`, new workspace `w5` label `nw`, new tab `w5:t1` label `main`): lifecycle events in the 0.7s window were exactly `layout_updated, workspace_created, tab_created, tab_closed, pane_moved`; 0 `pane_closed`/`pane_created` events referencing the moved pane (0 anywhere in the window). `pane.moved` is authoritative for re-keying.
- Case 7 polarity table for `layout.set_split_ratio`: `path:[]` addresses the root split (root.ratio -> 0.7); `path:[true]` addresses the nested/second-child split (root.ratio stays 0.7, nested.ratio -> 0.2); `path:[false]` on this tree returns `error.code=split_not_found`.
- Case 1b: nil `target_pane_id` on `pane.move` splits against the destination tab's **focused** pane, not tab history (moved pane landed sharing a y-band with the focused pane, `w2:p4`).
- Case 4: `split:right` places the moved-in pane to the right (p1.x=0, p3.x=30 before swap); after `pane.swap`, p3.x=0 < p1.x=30, i.e. swap flips left/right.
- Case 5: same-tab move is a no-op (`changed:false reason:same_tab`); bounce-out/bounce-back round-trips the same pane id.
- Case 6: zoom guard blocks a move (`changed:false reason:zoomed_tab`), then succeeds after un-zoom (tabA.pane_count=3).
- Event-echo timing, n=17 samples (ms): min=24, median=78, max=111.
- Wire shape confirmed here for every mutating verb: response nests one level under `.result` (`.result.move_result`, `.result.swap`, `.result.layout`, `.result.snapshot`).

Consequences for the plan:
- Tasks 20/23 can treat `pane.moved` as authoritative for local pane-id re-keying without reconciling a close/create pair, per Case 3.
- Tasks 20/23's geometry engine must implement the exact path-polarity mapping from the table above (`[]` = root, `[true]` = nested/second child, `[false]` here = not-found) rather than guessing.
- Task 11's client-side response typing must unwrap one level under `.result` for every verb (`move_result`, `swap`, `layout`, `snapshot`, etc.), consistent with Spike 2's wire assumptions.

## Spike 4: Observe streams into SwiftTerm at scale + backfill (Tasks 17, 18)

**Verdict: PASS on bridge/scale/backfill, with load-bearing caveats.**

Decisive facts:
- SwiftTerm pin: tag `1.20.0`, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`.
- Brief's skeleton has one wrong parameter name: `translateToString` takes `trimRight:`, not `trimmingRight:`.
- **Caveat 1 (most load-bearing): mismatched observe `--cols/--rows` top-crops, not tail-crops.** A pane's real size must be discovered first (e.g. in-pane `stty size`, since `pane.get` does not expose column width); a mismatch silently shows the top of the buffer instead of the cursor/tail, with `pane.get.scroll.viewport_rows` unchanged (the real pane is not resized).
- **Caveat 2:** an astral-plane emoji (`U+1F680`, rocket, raw bytes `f0 9f 9a 80`) is silently dropped by `term.feed(byteArray:)` in this SwiftTerm version, reproduced twice on two panes.
- **Caveat 3:** `translateToString(trimRight:)` only trims null-code cells; `pane read --source visible` drops fully blank trailing rows entirely. The two must be normalized before diffing.
- Scale probe (1/10/30 concurrent observe children, 60s window): steady-state CPU stayed under 1% of one core in all cases; RSS deltas were `+432 KB (+2.2%)` at 1 pane, `+1,680 KB (+1.7%)` at 10, `+3,984 KB (+1.5%)` at 30. No degradation ceiling found at this scale with this workload.
- Backfill (`pane.read {source:"recent", format:"ansi", lines:1000}`) preserved per-cell SGR through a 600-line colored history; `rowColors()` showed the exact `ansi256(4)|ansi256(5)|ansi256(6)|ansi256(1)|ansi256(2)|ansi256(3)` cycle from the generator.
- Alt-screen (vim) pane: `lines:1000` and `lines:40` (=viewport_rows) returned byte-identical output, both in ~6-12ms, because the pane was not a recognized agent (no synthetic-scroll jerk path triggered). This does not verify the recognized-agent jerk risk.

Consequences for the plan:
- Task 18 must discover each pane's real size (in-pane `stty size` or an equivalent authoritative source) before issuing observe `--cols/--rows`; a mismatch is a silent stale-view failure mode, not an obvious error.
- Task 18 must fix the brief's skeleton typo (`trimmingRight` -> `trimRight`) and normalize blank-row/whitespace trimming conventions before any exact-match diff against herdr's own read paths.
- Task 18 needs a follow-up spot-check of SwiftTerm's Unicode handling (at least the dropped astral-plane emoji) before treating rendering as fully general-purpose.
- Task 18's backfill path can safely request `lines:1000` for alt-screen/non-recognized-agent panes; for recognized-agent panes, treat a large `lines` value as unverified until the e2e phase confirms it does not trigger a scroll jerk.
- Task 17's LRU/pane-count cap is not located by this spike (30 panes used only 0.6% of one core, ~170x margin); Task 17 needs a heavier synthetic load or production telemetry, not this number, to find the real degradation knee.

## Spike 5: XCUITest closed loop + headless accessibility (Tasks 29, 30, 31)

**Verdict: PASS on scripted drag and the herdr closed loop; SKIPPED on the headless SSH probe.**

Decisive facts:
- Step 1: `DragLoopUITests.testTwentyScriptedDragsLandTheDrop`, 20/20 (`SPIKE_RESULT drags_landed=20/20`), gated on the drop point actually landing inside the target frame, not just gesture completion.
- Step 2: **the macOS UI test runner is unconditionally App Sandboxed** (confirmed via `codesign -d --entitlements`); a custom entitlements file with `app-sandbox=false` on the test target did not change the generated `-Runner.app`'s entitlements. Consequence: `herdr ... server` cannot bind its listening socket from inside the sandboxed runner's child process (entitlements show `network.client=true` but no `network.server`, only a read-only filesystem exception).
- Fix pattern: start and seed the scratch herdr session in a plain, unsandboxed shell before `xcodebuild test`; the test only **attaches** to the already-running server. Client-only ops (seeding via `nc`, `session.snapshot` polling) work fine from inside the sandbox.
- `xcodebuild test` does not forward arbitrary env vars; only the `TEST_RUNNER_*` prefix convention (set in xcodebuild's own process environment) reaches the test host's environment.
- `session.snapshot`'s `tabs[]` is a **flat** list with each tab carrying its own `workspace_id`, not nested per workspace; an initial implementation that assumed nesting produced a false-negative pass.
- Final closed-loop result: drag -> `pane.move` (`new_tab` destination) -> independent `session.snapshot` connection observes the target workspace's tab count grow by exactly one, PASS in 4.2s.
- Step 3 (SSH headless probe): SKIPPED, not the brief's anticipated "Remote Login off" case (`nc -zv localhost 22` succeeds). Actual blocker: `ssh -o BatchMode=yes localhost true` fails with `Permission denied (publickey,password,keyboard-interactive)`, no authorized key configured; provisioning one was judged out of scope (a machine/credential change).
- No Accessibility/Automation permission dialog appeared in ~10 runs on this machine; this spike cannot distinguish "prior grant already exists for this Team ID" from "the mechanism doesn't prompt at all" without a clean-permissions VM.

Consequences for the plan:
- Task 29's `ScratchSession.start()` cannot spawn the herdr server from inside XCTestCase code on macOS; it must either stay shaped as "attach to an already-running session" with the server spawn moved to a pre-test harness step (recommended), or gain a `TEST_RUNNER_*` bridge for anything it can't derive from files/sockets already on disk.
- Tasks 29-31 must pass any custom env vars into the test host via `export TEST_RUNNER_*` before invoking `xcodebuild test`; a plain `export` or a trailing xcodebuild argument does not work.
- Tasks 29-31's snapshot-parsing code must treat `session.snapshot.tabs[]` as flat and filter on each tab's own `workspace_id`, never assume workspace-nested tabs.
- Tasks 30-31's more elaborate drags (spring-load dwell, edge zones) will need longer holds/dwells than the `press(forDuration: 0.3, ...)` proven sufficient here for the simple two-target case.
- Tasks 29-31's e2e harness bring-up (or its onboarding doc) should assume a first-ever run on a fresh machine may need one human click through an Accessibility/Automation dialog, since this spike could not rule that out.
- The headless CI path (Step 3) remains unverified; a future run needs localhost key auth provisioned first, using the exact command recorded in the source file.

## Spike 6: Nested helper launch without a Gatekeeper prompt (Task 32)

**Verdict: PASS on all 3 launch paths (silent launch, clean and quarantined); recommendation is conditional pending notarization/clean-machine confirmation.**

Decisive facts:
- Signing identity: `Developer ID Application: Matthew Goodwin (5BF66B3X4V)`, hardened runtime, signed inside-out, **not notarized**.
- All three paths (`NSWorkspace.openApplication`, `SMAppService.loginItem`, `Process` exec) launched the helper silently, with no Gatekeeper prompt, in both clean and quarantined states, and each registers under its own distinct `CFBundleIdentifier` in LaunchServices (TCC identity comes from the code signature, not the launch path).
- `NSWorkspace.openApplication`: under quarantine, the helper is App-Translocated; `Bundle.main.bundlePath` reports a path under `AppTranslocation/<uuid>/...`, not the real install path.
- `SMAppService.loginItem`: hard packaging constraint, the helper must live at `Contents/Library/LoginItems/<Helper>.app`; a `Contents/Helpers/`-only variant fails registration with `SMAppServiceErrorDomain Code=22 "Invalid argument"` (reproduced every run).
- `Process` exec: never translocated in any state; the most predictable of the three for self-location, but looks like a deliberate Gatekeeper-bypass technique if audited.
- `spctl -a -vv` rejects both bundles in every state tested (`source=Unnotarized Developer ID`), while every one of the six live launch attempts (3 paths x clean/quarantined) succeeded with no block and no prompt; `spctl`'s static verdict and live launch behavior disagree.
- The single biggest open question: whether "no prompt" holds for a user who has never approved anything signed by this Developer ID before, versus this machine's per-Team-ID trust memory; not resolved without a notarized build or a clean machine/VM.
- Cleanup verified: no leaked `SpikeHelper`/`SpikeHost` processes, `SMAppService` unregistered (status `rawValue: 0`), no installed/blessed app bundle touched.

Consequences for the plan:
- Task 32 should use `NSWorkspace.shared.openApplication(at:configuration:)` from `Contents/Helpers/`; `SMAppService` is disqualified by its `Contents/Library/LoginItems/` location constraint and its login-item semantics, and raw `Process` exec forgoes LaunchServices integration for no observed benefit.
- Task 32 must not resolve helper identity or resources via `Bundle.main.bundlePath`; the chosen path translocates the helper under quarantine, so resources must be resolved relative to a path handed in at launch (e.g. launch configuration arguments or an environment variable).
- Task 32 must confirm the "no prompt" result against a notarized build or a genuinely clean machine/user before shipping it as final; the current result may be specific to this development machine's prior trust of this signing identity.

## Spike 7: Protocol floor pinned

**Verdict: PASS. MINIMUM_PROTOCOL = 22 confirmed.**

Decisive facts:
- `herdr --version`: `0.9.0`. Schema protocol field: `22` (`herdr api schema --json | jq '.protocol'`).
- All required methods present in the schema: `pane.scroll`, `pane.selection.read`, `pane.copy_search`, `pane.link.activate`, `pane.input.set`, `tab.move`, `workspace.move`.
- Live socket `ping` on a scratch session (`flock-proto2`) returned `"version": "0.9.0", "protocol": 22`, with capabilities `live_handoff: true, detached_server_daemon: false, endpoint_protocol_generation: 1, surface_interest: true, health_check: true`.
- `spikes/03-verbs/run.sh` re-run against herdr 0.9.0 / protocol 22: `PASS=9 FAIL=0 DIVERGED=0`, identical to the 0.8.0 run in Spike 3.
- Preview channel version was not remotely determinable within ~10 minutes of probing; stable ships 0.9.0/protocol 22, which meets the floor.
- Conclusion in source: no plan-constraint change needed, Global Constraints already specifies 22.

Consequences for the plan:
- Confirms the plan's existing Global Constraints value (MINIMUM_PROTOCOL = 22) needs no amendment.
- Establishes that Spike 3's verb matrix (feeding Tasks 20/23) and Spike 2's connection-per-request contract (feeding Task 11) both hold unchanged on the 0.9.0/22 build the plan will actually ship against, not just on the 0.8.0 build most spikes ran under.

## Cross-cutting facts

- **One-request-per-connection contract + never-write-on-stream rule, source-verified at both v0.8.0 and HEAD (0.9.0).** Spike 2 established it against herdr 0.8.0 (a second write on an answered connection gets `EPIPE`; a second write on an `events.subscribe` connection tears down the whole subscription). Spike 3 exercised it case-by-case (one-shot connection per mutating call, subscription connection never interleaved) still against 0.8.0. Spike 7 then re-ran the identical verb matrix (`spikes/03-verbs/run.sh`) against herdr 0.9.0 / protocol 22 and got the same `PASS=9 FAIL=0 DIVERGED=0`, so the contract holds unchanged across the version bump that happened mid-phase.
- **Wire responses nest one level deep.** Every mutating verb in Spike 3's raw captures returns its payload under a single named key inside `.result`: `.result.move_result` (pane.move), `.result.swap` (pane.swap), `.result.layout` (layout.set_split_ratio / layout.export), `.result.snapshot` (session.snapshot). Client-side response typing (Task 11) should unwrap exactly one level, not assume a flat `.result`.
- **herdr updated to 0.9.0/protocol 22 mid-phase via live handoff.** Spikes 2, 3, and the Tests/Fixtures capture ran against herdr 0.8.0 (protocol 19); Spike 4 and Spike 7 ran against herdr 0.9.0 (protocol 22), with Spike 7's live `ping` capabilities showing `live_handoff: true` as the mechanism that carried the upgrade. Spike 7 re-ran Spike 3's verb matrix on the new build and got the same 9/9 pass, so the mid-phase upgrade did not regress anything the earlier spikes had already verified.
- **MINIMUM_PROTOCOL = 22**, confirmed live against a real 0.9.0 socket (schema `.protocol` field and live `pong.protocol` both `22`), with all required methods for the plan present in that schema and no Global Constraints amendment needed.
