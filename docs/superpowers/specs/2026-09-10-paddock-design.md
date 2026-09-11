# Paddock: native herdr layout controller

**Date:** 2026-09-10
**Status:** Spec approved pending Matt's review
**Repo:** `~/Documents/GitHub/paddock` (new; ships inside mattstack.app)

## One-liner

A native macOS window that mirrors the entire herdr session live (1:1 terminal
content per pane) and gives total drag-and-drop control over workspaces, tabs,
and panes. Changes flow both ways in realtime: herdr events update the view;
view gestures mutate herdr.

## Why

Rearranging herdr panes/tabs today means remembering CLI verbs and ephemeral
pane ids. Paddock replaces that with direct manipulation. Longer term (post-v1)
it is the seed of a full Mac-native alternate herdr controller.

## Decisions already made

| Decision | Choice |
| --- | --- |
| Home | New repo `paddock`, built as `Contents/Helpers/Paddock.app` inside mattstack.app, launched from the tray |
| Pane fidelity | Full 1:1 terminal content, scrollable, live. Deep history (scrollback beyond the streamed/backfilled buffer, via `pane.selection.read`) is IN v1; it is the feature the protocol floor exists for |
| v1 scope | Full drag inventory (below) + rename/close/zoom/focus at all levels |
| v1 input | Typing-lite via `pane.send_input` (text + named keys: enter, esc, arrows, backspace, tab, ctrl combos): enough to run commands and drive agent TUI menus, with echo arriving over the observe stream (24-111ms). Full-fidelity raw input (mouse forwarding, kitty protocol, exclusive ownership) stays v1.5 (`terminal session control --takeover`) |
| herdr version | Assume upgraded herdr: target the protocol >= 22 surface (`pane.scroll`, `pane.selection.read` era). Startup does `ping`; below the floor, paddock shows "run `herdr update`" and exits gracefully |
| Process | Spike-first: nothing lands in the implementation plan unvalidated. Fully automated interactive e2e tests are the completion bar |
| UI process | Design canvas + reference PNGs signed off before any UI code |

## The herdr contract (verified 2026-09-10)

### Transport

NDJSON over unix socket. Default `~/.config/herdr/herdr.sock`; named sessions
at `~/.config/herdr/sessions/<name>/herdr.sock`. Resolution order: `--session`
> `HERDR_SOCKET_PATH` > `HERDR_SESSION` > default. Request
`{id, method, params}` per line; response `{id, result}` or `{id, error:{code,
message}}`. `events.subscribe` holds its connection open and streams events.
Socket perms 0600. `ping` returns `{version, protocol}`.

### Bootstrap (documented protocol)

1. Open connection A, `events.subscribe` (all lifecycle types + `layout.updated`
   + per-pane parameterized subs as needed), wait for ack, buffer events.
2. On connection B, `session.snapshot` (workspaces, tabs, panes, per-tab layout
   snapshots with pane rects + BSP split trees + ratios, agents, focus).
3. Install snapshot, replay buffer in order, continue streaming.
4. Re-snapshot: on reconnect, after live handoff, and on a slow safety timer.
   The event stream is server-polled at 100ms with a 512-event ring and NO
   replay or gap signal; the periodic re-snapshot is the correctness backstop.

### Mutation verbs

| Gesture | Verb |
| --- | --- |
| Pane to edge of another pane | `pane.move {type:"tab", tab_id, target_pane_id, split:"right"\|"down", ratio}` |
| Pane to left/up edge | compose: split right/down, then `pane.swap` the pair |
| Pane to tab thumbnail | `pane.move {type:"tab", tab_id, split}` (defaults to focused pane of target tab) |
| Pane to "new tab" zone | `pane.move {type:"new_tab", workspace_id, label}` |
| Pane to "new workspace" zone | `pane.move {type:"new_workspace", label, tab_label}` |
| Pane onto pane interior, same tab | `pane.swap {source_pane_id, target_pane_id}` |
| Same-tab restructure (not a swap) | compose: `pane.move` to temp `new_tab`, then `pane.move` back into position, close temp tab |
| Divider drag | `layout.set_split_ratio {tab_id, path:[bool...], ratio}` |
| Tab reorder | `tab.move {tab_id, insert_index}` |
| Whole tab to another workspace | compose: first pane via `pane.move new_tab` in target, rest via `pane.move tab` into it, preserving split shape from the source layout snapshot |
| Workspace reorder | `workspace.move` / `workspace.move_block` (multi-select) |
| Rename | `workspace.rename` / `tab.rename` / `pane.rename` (null label clears) |
| Close | `pane.close` / `tab.close` / `workspace.close` |
| Zoom | `pane.zoom {mode: toggle\|on\|off}` |
| Jump herdr there | `workspace.focus` / `tab.focus` / `pane.focus` / `agent.focus` |

### Hard constraints (from source, must shape the UX)

- `pane.swap` is same-tab only (`cross_tab`). `pane.move` refuses same-tab
  (`same_tab`) and refuses zoomed source or target tabs (`zoomed_tab`).
  Paddock auto-unzooms with a toast before a move.
- `layout.apply` creates FRESH panes: it never preserves live PTYs, scrollback,
  or processes. It must never be used to reflow live work. Undo is therefore an
  inverse-operation journal, not export/reapply.
- Cross-workspace `pane.move` keeps the terminal alive but assigns a new pane
  id; continue with `.result.move_result.pane.pane_id`. No fake close/create
  events are emitted; listen for `pane.moved`.
- `workspace.close` on a primary with open linked-worktree workspaces returns
  `workspace_group_close_required` unless `close_group: true`; paddock asks.
- Methods with optional target ids fall back to the HUMAN's focused pane.
  Paddock always sends explicit ids.
- `pane.read` `lines` is clamped to 1000; its `revision` field is always 0
  (use `PaneInfo.revision`). Raw-socket reads are `Interactive` intent: on
  idle alt-screen agents with `lines > viewport_rows`, newer herdr synthesizes
  wheel events into the live pane (visible to the user, up to 15s). Backfills
  for alt-screen agent panes cap `lines` at `viewport_rows`.
- Public pane/tab ids survive server restarts (persisted); closed ids are
  never reused. Live handoff preserves PTYs but drops subscriptions: paddock
  reconnects and re-bootstraps.
- Newer-than-0.8.0 verbs paddock uses behind its protocol floor:
  `pane.scroll {pane_id, offset_from_bottom}`, `pane.selection.read`
  (absolute-row full-scrollback text reads with `content_revision` tear
  guard), `pane.copy_search`. These have schema presence but no prose
  stability contract: pin exact behavior in spikes and diff `herdr api schema
  --json` on each herdr update.

### Live 1:1 pane content

- **Stream:** `herdr terminal session observe <pane_id> --cols N --rows M`,
  one child process per attached pane. NDJSON frames:
  `{"type":"terminal.frame","seq","encoding":"ansi","width","height","full","bytes":<base64>}`
  then `terminal.closed`. Multiple observers allowed; observe takes no input
  authority. Docs name this the third-party bridge path. Paddock shells out to
  the herdr binary rather than speaking `herdr-client.sock` (that protocol is
  strict version-matched; the CLI is the stable adapter).
- **Renderer:** SwiftTerm view per attached pane (MIT, active), fed the ANSI
  bytes, read-only in v1. Local scrollback accumulates from attach.
- **Backfill:** one `pane.read` (`recent`, `format: ansi`, <= 1000 lines,
  alt-screen cap above) seeds history at attach.
- **Deep history:** `pane.selection.read` chunks (plain text) render as a
  "history" region above the live buffer on demand. `pane.scroll` is NOT used
  for paddock-local scrolling (it yanks the user's real viewport); it exists
  only behind an explicit "scroll herdr's view" affordance if ever wanted.
- **Attach policy:** streams for visible + selected panes with an LRU cap
  (target ~30, spike-validated); detached panes show status cards (title,
  label, cwd, agent badge, last line from snapshot data). Frame updates
  coalesce; offscreen SwiftTerm views do not layout.

## Architecture

Swift 6, SwiftUI, macOS 15+, single window. Three planes:

1. **`HerdrStore` (actor):** owns the sockets, the bootstrap dance, the
   normalized model (workspaces/tabs/panes/layouts/agents/focus), and event
   application. Publishes `@Observable` state to the UI. Also owns the
   re-snapshot backstop and reconnect.
2. **`ContentPlane`:** observe-process supervisor (spawn, reap, restart on
   `terminal.closed`, LRU), per-pane SwiftTerm bridge, backfill fetches.
3. **`MutationEngine`:** compiles gestures into plans of primitive ops.
   Optimistic local apply, execute sequentially, converge on echoed events,
   typed-error rollback with reason surfaced. Maintains the inverse-op
   journal for Cmd+Z. Composed sequences (left/up drop, same-tab bounce,
   whole-tab migration) execute as one journal entry and one visual
   transaction.

The **drag layer** is a custom in-window system (no NSDraggingSession, no
Transferable): a DragGesture-driven state machine, floating ghost overlay,
dropzone hit-testing against the layout model, all animation on
transform/opacity only, interruptible springs.

## Interaction spec (mined patterns, concrete values)

- **Pane drop semantics (VS Code model):** interior of a target pane = swap
  (same tab) or move-onto (cross tab); outer 20% edge band = directional
  split drop with live overlay preview of the resulting rects.
- **Insertion bars (Atlassian tokens):** 2px accent line with 8px terminal
  dot in the gap between tabs/workspaces during reorder drags.
- **Ghost:** origin stays at 40% opacity; proxy follows cursor offset ~16x8px;
  no tilt for pane cells (they are content surfaces).
- **Reshuffle:** ~100ms slide, triggered when the dragged item's CENTER
  crosses a neighbor boundary.
- **Springs:** interruptible, duration/bounce parameterization (WWDC23 model);
  drop settles fast enough that immediate re-grab works.
- **Spring-loading:** hovering a collapsed workspace/tab 500ms mid-drag opens
  it in place and the drag continues inside; Space forces instantly.
- **Cancel/commit:** Esc always cancels with spring-back to origin; invalid
  drops bounce home along the same motion curve; successful drops flash the
  landing zone ~700ms.
- **Rename:** double-click or F2, inline editor, drag-arming disabled while
  editing (VS Code PR #166821 trap).
- **Close:** hover-reveal x. **Zoom:** badge + double-click-zoom modifier.
- **Keyboard/accessibility parity:** context menus on everything plus a
  "Move to..." picker (destination list) covering every drag outcome;
  arrow-key move/swap for the focused pane; accessibility identifiers on all
  interactive elements (also required by the e2e suite).
- **Auto-scroll** near strip/rail edges with proximity-ramped velocity.
- **Agent status colors mirror herdr's header semantics** (source:
  `src/client/shell.rs` `status_color`): working = yellow, blocked = red,
  done = teal, idle = green, unknown = dim overlay. v1 pins the Tokyo Night
  values (`#E0AF68` / `#F7768E` / `#7DCFFF` / `#9ECE6A` / `#565F89`; light
  chrome uses the Tokyo Night Day values), matching what theme = "terminal"
  resolves to on this machine. Dot FILL mirrors herdr's dots style
  (`status_icon`): working/blocked/done are filled, idle is a hollow ring,
  unknown is a small centered dot. The zoom badge is mauve (`#BB9AF7`),
  never a status color.
- **Copy on selection (herdr parity, v1):** mouse-up ends a selection in a
  live pane and the text is already on the clipboard (herdr ships
  `copy_on_select = true`); a quiet "Copied N lines" whisper confirms.
  Selection is paddock-local: it never moves herdr's cursor or viewport.
- **Right-click routing (herdr 0.9, v1):** paddock surfaces the per-pane
  `pane.input.set { right_click: "pane" | "herdr" }` toggle in its pane
  context menu and pane header, reflecting the live routing state. The
  Option+click gesture (one-off right-click delivered INTO the pane app,
  mirroring herdr's `ui.right_click_passthrough_modifier`) is first-class in
  the design but ships with the v1.5 input channel; no API delivers a mouse
  event from outside today (`pane.send_input` takes text/keys only).
- **Attention toasts (v1):** top-right stack derived from
  `pane.agent_status_changed` / `pane.agent_detected` (blocked = needs
  input, working-to-idle/done = finished). Click = jump: `workspace.focus` +
  `tab.focus` + `pane.focus` with explicit ids, window to front. Quiet
  rules: no toast for the focused pane, 2s coalescing on status flaps, max
  3 deep with a "+N more" pill; blocked toasts persist until handled,
  done toasts auto-dismiss 6s (hover pauses). herdr's `notification.show`
  traffic is NOT observable on the api socket (no notification event kind);
  mirroring third-party herdr toasts 1:1 needs an upstream herdr
  `notification.shown` event (documented ask, out of scope).

- **New panes are real shells, born useful (v1):** paddock creates panes,
  tabs and workspaces for real (`pane.split`, `tab.create`,
  `workspace.create`, with cwd control); herdr spawns a genuine shell. A
  pane created from paddock shows its bare prompt (typable immediately via
  send_input) and fills the empty space below the prompt with launcher
  buttons for the CLI agent harnesses installed on the machine (PATH probe
  of a known roster: claude, codex, ...; extensible). Clicking one sends
  `<binary>\n` to the pane. The buttons exist only while the pane is
  pristine: the first keystroke or the first output beyond the prompt hides
  them, so a user who just wants to run a command never fights them.

## Hands-on checkpoints

The build pauses at natural try-it points so feedback lands while it is
cheap. At each checkpoint paddock is built and launched for real use
against the live session (a checkpoint stop, not a review artifact):

1. After the shell UI lands (rail/strip/canvas + focus jumps): the first
   runnable read-only mirror.
2. After live 1:1 content + deep history: the full read-only product.
3. After the mutation engine + undo (pre-drag): every rearrange works via
   context menus and "Move to...".
4. After the core drag layer: hands-on drag/drop.
5. After the full drag inventory + notifications/pointer features: the
   complete v1 surface, pre-e2e.

Each checkpoint is a STOP: Matt tries it and gives feedback; feedback folds
into the plan before the next phase proceeds.

## Validation pipeline

### Phase 0 spikes (each with a pass/fail criterion, before the plan freezes)

1. **Socket client:** DispatchIO NDJSON framing under a 1000-line burst incl.
   >64KB lines; subscription stream stays ordered and cancellation unblocks.
2. **Observe-to-SwiftTerm:** 1 / 10 / 30 concurrent observe streams into
   SwiftTerm views; budget: < 1 core total steady-state, RSS bounded, no
   frame tearing.
3. **Mutation verbs live:** every `pane.move` destination type, composed
   left/up drop, same-tab bounce, whole-tab migration, against a named
   scratch session; assert via `session.snapshot`; measure event echo timing.
4. **`layout.set_split_ratio` path semantics** (boolean path into BSP tree).
5. **Backfill behavior** on the current binary: `pane.read` ansi fidelity into
   SwiftTerm; alt-screen agent pane behavior with capped lines.
6. **XCUITest closed loop:** scripted real drag on the app changes herdr
   (snapshot-asserted) and the view converges.
7. **Nested helper launch:** Paddock.app inside a signed host bundle launches
   from a menu-bar app without a Gatekeeper prompt (test NSWorkspace vs
   alternatives; research flags this as a real shipping risk).
8. **Headless accessibility grant** for XCUITest on a clean machine/VM; if
   the local grant is flaky, fall back to the existing VM harness.
9. **Protocol floor check:** confirm what `herdr update` (stable vs preview
   channel) actually ships for `pane.scroll` / `pane.selection.read`, and pin
   paddock's minimum protocol number.

### E2E suite (the completion bar)

Isolated `herdr --session <scratch>` per test run: seed a scripted layout over
its socket, launch Paddock with `HERDR_SOCKET_PATH` pointed at it, drive real
gestures via XCUITest, assert BOTH herdr ground truth (`session.snapshot`) and
rendered state (accessibility tree). Every row of the mutation-verb table gets
at least one case, plus: external-change convergence (mutate herdr from the
test, view updates), reconnect/re-bootstrap, event-overflow re-snapshot, undo
round-trips, zoom guard, group-close prompt. The suite must run unattended.

## Shipping

Xcode project generated by XcodeGen (checked-in `project.yml`). Signed +
hardened Paddock.app; ships at `Contents/Helpers/Paddock.app` in mattstack.app
via the deck/bundle pipeline; tray menu item launches it (mechanism per spike
7). Dev loop runs the app standalone from the paddock repo against a scratch
session.

## Non-goals (v1)

- No full-fidelity input: v1 typing is send_input-based (see Decisions), so
  no mouse forwarding into panes, no kitty/raw protocol passthrough, no
  exclusive input ownership (v1.5: `terminal session control --takeover`;
  the pane component is already a terminal emulator, so the rest is UX +
  ownership semantics, not rendering work).
- No `herdr-client.sock` / client-shell endpoint usage (revisit only with
  upstream buy-in; it is the internal surface that streams cell grids).
- No layout templates/snapshot library (`layout.apply` fresh-tab templating is
  a natural v2).
- No remote (`--machine`) sessions, no Windows.

## Future notes

- Companion herdr plugin: `[[startup]]` hook to auto-launch paddock,
  `[[actions]]` + keybinding to summon it from the TUI, `[[events]]` hooks as
  a push channel that bypasses the 100ms poll.
- rt intelligence: workspace naming suggestions, stuck-agent summaries,
  chat/status integration via the rt daemon.
- Paddock-owned display state can ride herdr's metadata tokens
  (`pane.report_metadata` / `workspace.report_metadata`, TTL-capped).
