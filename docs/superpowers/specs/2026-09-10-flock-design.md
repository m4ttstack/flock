# Flock: native herdr layout controller

**Date:** 2026-09-10
**Status:** Spec approved pending Matt's review
**Repo:** `~/Documents/GitHub/flock` (new; ships inside mattstack.app)

## One-liner

A native macOS window that mirrors the entire herdr session live (1:1 terminal
content per pane) and gives total drag-and-drop control over workspaces, tabs,
and panes. Changes flow both ways in realtime: herdr events update the view;
view gestures mutate herdr.

## Why

Rearranging herdr panes/tabs today means remembering CLI verbs and ephemeral
pane ids. Flock replaces that with direct manipulation. Longer term (post-v1)
it is the seed of a full Mac-native alternate herdr controller.

## Decisions already made

| Decision | Choice |
| --- | --- |
| Home | New repo `flock`, built as `Contents/Helpers/Flock.app` inside mattstack.app, launched from the tray |
| Pane fidelity | Full 1:1 terminal content, scrollable, live. Deep history (scrollback beyond the streamed/backfilled buffer, via `pane.selection.read`) is IN v1; it is the feature the protocol floor exists for |
| v1 scope | Full drag inventory (below) + rename/close/zoom/focus at all levels |
| v1 input | Typing-lite via `pane.send_input` (text + named keys: enter, esc, arrows, backspace, tab, ctrl combos): enough to run commands and drive agent TUI menus, with echo arriving over the observe stream (24-111ms). Full-fidelity raw input (mouse forwarding, kitty protocol, exclusive ownership) stays v1.5 (`terminal session control --takeover`) |
| herdr version | Assume upgraded herdr: target the protocol >= 22 surface (`pane.scroll`, `pane.selection.read` era). Startup does `ping`; below the floor, flock shows "run `herdr update`" and exits gracefully |
| Process | Spike-first: nothing lands in the implementation plan unvalidated. Fully automated interactive e2e tests are the completion bar |
| UI process | Design canvas + reference PNGs signed off before any UI code |
| Architecture process (ruled 2026-09-14) | Read Herdglass (`~/Documents/GitHub/Herdglass`) on the same concern BEFORE any architectural decision, state its answer, and justify every divergence. Flock's renderer is a port of it; the one standing reason to diverge is that flock coexists with Matt's herdr TUI while Herdglass replaces it |

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
  Flock auto-unzooms with a toast before a move.
- `layout.apply` creates FRESH panes: it never preserves live PTYs, scrollback,
  or processes. It must never be used to reflow live work. Undo is therefore an
  inverse-operation journal, not export/reapply.
- Cross-workspace `pane.move` keeps the terminal alive but assigns a new pane
  id; continue with `.result.move_result.pane.pane_id`. No fake close/create
  events are emitted; listen for `pane.moved`.
- `workspace.close` on a primary with open linked-worktree workspaces returns
  `workspace_group_close_required` unless `close_group: true`; flock asks.
- Methods with optional target ids fall back to the HUMAN's focused pane.
  Flock always sends explicit ids.
- `pane.read` `lines` is clamped to 1000; its `revision` field is always 0
  (use `PaneInfo.revision`). Raw-socket reads are `Interactive` intent: on
  idle alt-screen agents with `lines > viewport_rows`, newer herdr synthesizes
  wheel events into the live pane (visible to the user, up to 15s). Backfills
  for alt-screen agent panes cap `lines` at `viewport_rows`.
- Public pane/tab ids survive server restarts (persisted); closed ids are
  never reused. Live handoff preserves PTYs but drops subscriptions: flock
  reconnects and re-bootstraps.
- Newer-than-0.8.0 verbs flock uses behind its protocol floor:
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
  authority. Docs name this the third-party bridge path. Flock shells out to
  the herdr binary rather than speaking `herdr-client.sock` (that protocol is
  strict version-matched; the CLI is the stable adapter).
- **Renderer:** libghostty, integrated by PORTING Herdglass
  (github.com/buldezir/Herdglass, BSL-1.1; attribution owed in
  THIRD-PARTY-NOTICES on any publish). DECIDED 2026-09-11 by Matt (two
  rulings: libghostty final; then, after the Herdglass study, "port into
  flock"), superseding SwiftTerm after checkpoint testing showed the
  integration seams (font fit, sizing, theming) are exactly what a
  Ghostty surface does natively. The mechanism is NOT byte-feeding: the
  ghostty surface owns a real PTY whose child is a flock bridge
  process translating `herdr terminal session control <pane>` NDJSON to
  raw PTY bytes; input rides `ghostty_surface_key` (kitty-aware, IME);
  the surface computes its grid from pixel size. Flock adds what
  Herdglass lacks: mouse-reporting passthrough and read-only unfocused
  panes. EVERY visible pane is one ghostty surface for its whole life
  (ruled 2026-09-12 at Checkpoint 2b, after a focus-swap hybrid produced
  font jumps, banner flashes, and cursor artifacts at every seam): the
  bridge holds a control-mode attach (`terminal session control
  --takeover`) for its whole life (ruled 2026-09-14 with the sizing rule
  below; the earlier observe-until-focused bridge, switched in place over
  a flock-namespaced FIFO command, left unfocused panes at herdr's size
  and so re-wrapped a pane the moment it was focused). Input is written
  only to the flock-focused pane's surface; the others are attached but
  silent. Right-click on any pane opens the herdr action
  menu; it reaches the terminal only when the pane's routing toggle is
  on. The exact libghostty commit is pinned (Herdglass-validated
  08450e21e5a3ad94b62d1e67f9eda554dfa1c971, vendored via zig submodule
  build). SwiftTerm is fully retired. Plan Phase 2.5 carries the port
  tasks; the study report lives at
  `.superpowers/sdd/2026-09-10-flock/herdglass-study.md`.
- **Backfill:** one `pane.read` (`recent`, `format: ansi`, <= 1000 lines,
  alt-screen cap above) seeds history at attach.
- **Scrollback (ruled 2026-09-13 at Checkpoint 3, replacing the deep
  history overlay):** flock's libghostty holds no scrollback of its own
  because herdr streams viewport repaints, so the wheel on the focused
  (control-mode) pane is sent to herdr as `terminal.scroll {direction,
  lines, source: wheel}` through the bridge's control FIFO, exactly as
  herdr's own TUI and Herdglass do; herdr scrolls the pane's viewport and
  the scrolled content streams back with full color. The earlier rule that
  flock-local scrolling must never move the real viewport belonged to
  the passive-mirror design; flock is a controller now, and scrolling a
  pane in flock is the user scrolling that pane. Unfocused (observe-mode)
  panes ignore the wheel until focused. The SwiftUI history overlay and its
  `pane.selection.read` chunk loading are removed; `pane.selection.read`
  remains available for a future search feature only.
- **Sizing (ruled 2026-09-14, superseding the 2026-09-13 "herdr owns
  sizes" rule): flock owns every visible pane's size, the way
  Herdglass does.** Every visible pane holds a control-mode attach
  (`terminal session control <pane> --takeover`) for its whole life, and
  each bridge resizes that pane's REAL runtime to its own surface grid
  (herdr `headless.rs` `ClientResize` -> `TerminalAttach` ->
  `runtime.resize`). Herdglass sizes panes exactly this way
  (`Sources/HerdrClient/ControlBridge.swift`, `terminal.resize` from the
  bridge PTY's winsize) and never touches a session area; flock follows
  it because no herdr verb lets a non-shell client set the area at all
  (it is the foreground client's terminal size, else
  `server.headless_cols/rows`), so the uniform-cell mirror could only ever
  letterbox inside herdr's 120x40 default.

  Consequences, all intended: the canvas fills the window, splits laid out
  from `layout.export` ratios; growing the flock window grows the real
  panes; nothing re-wraps on focus, because focus no longer changes any
  pane's size. Where flock diverges from Herdglass is that Matt runs the
  herdr TUI alongside, and that costs less than the ruling assumed:
  `attach_terminal_client` takes a `direct_attach_resize_lock` per
  attached terminal and the TUI skips its own resize for a locked pane,
  so while flock is open it HOLDS every visible pane's size and the TUI
  does not take it back. The TUI shows those panes at flock's dims
  inside its own layout (clipped or short wherever the two disagree)
  until flock detaches. Reflow on switching was accepted anyway (ruled
  by Matt: "herdr is really good at responding to resizes"). The Terminal Text setting (Compact/Regular/Large) is the font
  size outright, not a maximum; each pane's cols x rows is its box divided
  by that font's cell metrics, with the remainder as padding inside the
  box. Real pane resizes are LIVE during every drag (window resize and divider drag alike), sent the moment a pane's whole-cell grid changes, exactly as Herdglass does (`TerminalSurfaceView.layout()` resizes the surface, whose bridge sends `terminal.resize` on SIGWINCH with no coalescing); only the split RATIO waits for release (ruled 2026-09-15 after Matt saw divider drags correct only on release, caused by an earlier ruling that held pane dims for the drag and misapplied Herdglass's ratio rule to sizes). The ORDER matches Herdglass too (ruled 2026-09-15): herdr is told a
  pane's new size only after that pane's PTY has actually taken it, driven
  by the bridge's own SIGWINCH, never ahead of it from the app's box dims.
  libghostty applies a new grid to its terminal after a 25ms debounce
  (`Vendor/ghostty/src/termio/Thread.zig:31`), so a resize sent from the
  box reached herdr first and herdr's full frame for the new size was
  parsed into the old grid; sending from SIGWINCH makes that impossible by
  construction and retires the bridge's frame gate, its 200ms fallback and
  the forced settle repaint. A scroll indicator fed by herdr's own scroll state
  (offset_from_bottom, `pane.scroll_changed`) shows when a pane's viewport
  is above its tail.
- **Tab following (ruled 2026-09-13):** flock's selected tab follows
  herdr's focused tab whenever herdr's focus changes (a tab switch is a
  warm re-host of parked surfaces, so following is cheap); a
  flock-initiated selection persists until herdr's focus next changes.
  Pane surfaces are parked, not destroyed, when their tab leaves the
  screen (LRU cap 12), so returning to a tab shows current content
  without a flash; cold attaches show the status card until the first
  full frame, then crossfade.
- **Attach policy:** streams for visible + selected panes with an LRU cap
  (target ~30, spike-validated); detached panes show status cards (title,
  label, cwd, agent badge, last line from snapshot data). Frame updates
  coalesce; offscreen SwiftTerm views do not layout.
- **All Workspaces grid (ruled 2026-09-15, design in `flock-colors.pen`,
  All workspaces columns):** one card per workspace. At rest a card shows
  its first three tabs as layout thumbnails plus a "+N" tile for the rest;
  clicking the tile (or dwelling on it 500ms mid-drag, so hidden tabs can
  still take a drop) expands that card to every tab, four per row, and the
  grid scrolls. Every pane inside a thumbnail shows its title
  (`terminalTitleStripped ?? label`) with its agent status dot, small, and
  nothing else, never a blank box. Hovering a pane shows a hover card with
  the full status card: title, status, tab and pane position, cwd, and the
  last line of output (`pane.read {source:"visible", lines:1}`, fetched on
  hover and cached by `PaneRecord.revision`). No hover card while a drag is
  in flight. The grid never attaches panes: attaching sizes the real pane,
  so a live grid would resize all of herdr.

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

- **Pane anatomy (Matt's ruling 2026-09-13, herdr parity):** no header
  row. The pane title, status dot, and status chip sit as a legend inlaid
  on the top border line (herdr's fieldset style); the terminal body starts
  directly under the line, so the old 28px header becomes terminal rows.
- **Grabbing a pane (two coexisting ways):** (1) at rest, the legend plus a
  ~12px invisible band along the pane's top edge is the drag handle; a grip
  glyph fades in on hover. (2) REARRANGE MODE: one sticky state with one
  switch behind it, the View menu's Rearrange Mode item, which carries
  **Cmd+R** (ruled 2026-09-17). While active every pane repaints (terminal
  content dims but stays READABLE, border switches to the accent color, a
  centered grip glyph appears, hover lifts the pane a hair) and a drag can
  start from ANY point on a pane, with mouse events no longer forwarded to
  the terminal. Nothing in the mode may change a cell's frame: the rects the
  canvas lays cells out at are the rects the drop resolver hit-tests, so the
  hover lift is a shadow, never a scale. The mode is left by Cmd+R again,
  the menu item again, or Esc. Esc has a precedence rule: with a drag in
  flight it cancels the drag and leaves the mode alone, so leaving mid-drag
  takes two presses. A drag in progress finishes first.

  MODIFIER ROUTES ARE GONE (ruled 2026-09-17). Control was chosen first and
  is UNUSABLE: Control+click is a secondary click on macOS, so a press with
  Control held arrives as `rightMouseDown` and a drag can never begin.
  Option replaced it (held = momentary, double-tapped = sticky, ruled
  2026-09-14) and was removed after one live session: Option is a
  text-navigation modifier in the programs these panes run, so ordinary
  editing kept dimming every pane and taking the mouse off the terminal.
  Command is the only modifier a pane's program never receives, which is why
  the mode is a Command key equivalent and not a held key at all. Option now
  means exactly one thing on a pane, the herdr-menu right-click, and nothing
  else reads it.
- **Menu-bar key equivalents (one inventory):** Cmd+T new tab, Cmd+Shift+N
  new workspace, Cmd+X/C/V/A the standard editing items (routed through the
  responder chain, so an open rename field takes them before the terminal
  does), F2 rename, Cmd+Z / Cmd+Shift+Z undo/redo, Cmd+Option+arrows move
  pane, Cmd+Option+Shift+arrows swap pane, Cmd+R rearrange mode,
  Cmd+Shift+R All Workspaces (the same gesture at a wider scope: one
  workspace's panes, then across all of them), Cmd+K clear notifications,
  Cmd+minus / Cmd+0 / Cmd+plus terminal text size. Cmd+Shift+A is free and
  unassigned.

  The arrange pair is R and not D (ruled 2026-09-17, after one day on D):
  ghostty's own macOS defaults bind Cmd+D and Cmd+Shift+D to `new_split`, and
  Matt runs a real ghostty beside flock. The split actions are inert inside
  flock, so nothing broke... the clash was muscle memory. Cmd+R and
  Cmd+Shift+R are claimed by neither ghostty's default keybinds
  (`src/config/Config.zig`, which binds no Command+R at all) nor its menu bar
  (`macos/Sources/App/MainMenu.xib`), and by nothing in flock's own menus.
  `ArrangeShortcut` is where the pair is declared, once, for both items.
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
- **Themes, not light/dark modes (herdr parity):** flock has named
  themes exactly like herdr. `Theme` mirrors herdr's `Palette` shape
  (accent, panel_bg, sidebar_bg, active_row_bg, selection_bg, surface0/1,
  surface_dim, overlay0/1, text, subtext0, mauve, green, yellow, red, blue,
  teal, peach), and flock bundles herdr's 17 concrete built-ins
  transcribed VERBATIM from herdr `src/app/state.rs` (tokyo-night default;
  tokyo-night-day, catppuccin, catppuccin-latte, dracula, nord, gruvbox,
  gruvbox-light, one-dark, one-light, solarized, solarized-light, kanagawa,
  kanagawa-lotus, rose-pine, rose-pine-dawn, vesper). Theme picked in the
  View menu, persisted; macOS system appearance is ignored (herdr's
  "terminal" theme follows the host terminal and has no flock
  equivalent). All chrome derives from the active theme's tokens; the
  canvas references render Tokyo Night and Tokyo Night Day.
- **Agent status colors mirror herdr's header semantics** (source:
  `src/client/shell.rs` `status_color`), drawn from the ACTIVE theme:
  working = theme.yellow, blocked = theme.red, done = theme.teal,
  idle = theme.green, unknown = theme.overlay0. Dot FILL mirrors herdr's
  dots style (`status_icon`): working/blocked/done are filled, idle is a
  hollow ring, unknown is a small centered dot. The zoom badge is
  theme.mauve, never a status color.
- **Copy on selection (herdr parity, v1):** mouse-up ends a selection in a
  live pane and the text is already on the clipboard (herdr ships
  `copy_on_select = true`); a quiet "Copied N lines" whisper confirms.
  Selection is flock-local: it never moves herdr's cursor or viewport.
- **Right-click routing (herdr 0.9, v1):** flock surfaces the per-pane
  `pane.input.set { right_click: "pane" | "herdr" }` toggle in its pane
  context menu and pane header, reflecting the live routing state. The
  Right-click disposition (Matt's ruling 2026-09-13, inverting the
  earlier gesture): on the focused (control-mode) pane a PLAIN right-click
  lands in the pane app whenever that app has mouse reporting on (herdr
  reports the state as `MouseCapture`); when nothing in the pane is
  listening it falls through to the herdr action menu. Option+right-click
  always opens the herdr action menu. Unfocused (observe-mode) panes:
  right-click opens the menu, nothing ever forwards. Flock does not
  mirror herdr's per-pane `right_click` routing setting (herdr's own TUI
  keeps it); the flock context-menu toggle is gone.
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

- **New panes are real shells, born useful (v1):** flock creates panes,
  tabs and workspaces for real (`pane.split`, `tab.create`,
  `workspace.create`, with cwd control); herdr spawns a genuine shell. A
  pane created from flock shows its bare prompt (typable immediately via
  send_input) and fills the empty space below the prompt with launcher
  buttons for the CLI agent harnesses installed on the machine (PATH probe
  of a known roster: claude, codex, ...; extensible). Clicking one sends
  `<binary>\n` to the pane. The buttons exist only while the pane is
  pristine: the first keystroke or the first output beyond the prompt hides
  them, so a user who just wants to run a command never fights them.

## Hands-on checkpoints

The build pauses at natural try-it points so feedback lands while it is
cheap. At each checkpoint flock is built and launched for real use
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
7. **Nested helper launch:** Flock.app inside a signed host bundle launches
   from a menu-bar app without a Gatekeeper prompt (test NSWorkspace vs
   alternatives; research flags this as a real shipping risk).
8. **Headless accessibility grant** for XCUITest on a clean machine/VM; if
   the local grant is flaky, fall back to the existing VM harness.
9. **Protocol floor check:** confirm what `herdr update` (stable vs preview
   channel) actually ships for `pane.scroll` / `pane.selection.read`, and pin
   flock's minimum protocol number.

### E2E suite (the completion bar)

Isolated `herdr --session <scratch>` per test run: seed a scripted layout over
its socket, launch Flock with `HERDR_SOCKET_PATH` pointed at it, drive real
gestures via XCUITest, assert BOTH herdr ground truth (`session.snapshot`) and
rendered state (accessibility tree). Every row of the mutation-verb table gets
at least one case, plus: external-change convergence (mutate herdr from the
test, view updates), reconnect/re-bootstrap, event-overflow re-snapshot, undo
round-trips, zoom guard, group-close prompt. The suite must run unattended.

## Shipping

Xcode project generated by XcodeGen (checked-in `project.yml`). Signed +
hardened Flock.app; ships at `Contents/Helpers/Flock.app` in mattstack.app
via the deck/bundle pipeline; tray menu item launches it (mechanism per spike
7). Dev loop runs the app standalone from the flock repo against a scratch
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

- Companion herdr plugin: `[[startup]]` hook to auto-launch flock,
  `[[actions]]` + keybinding to summon it from the TUI, `[[events]]` hooks as
  a push channel that bypasses the 100ms poll.
- rt intelligence: workspace naming suggestions, stuck-agent summaries,
  chat/status integration via the rt daemon.
- Flock-owned display state can ride herdr's metadata tokens
  (`pane.report_metadata` / `workspace.report_metadata`, TTL-capped).
