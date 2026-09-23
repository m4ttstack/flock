# rt in flock

**Goal:** the rt commands used every day (`rt nav`, `rt glitter`, `rt run`,
`rt runner`) open from any pane in flock, in a terminal sized for the job rather
than for whatever split herdr has room for, with long-running work kept alive
and one click away.

**Status:** design approved 2026-09-23. flock only; rt is unchanged.

## Why

These commands run in a pane today, so they take a split from the layout they
are meant to serve. `rt nav` is mostly used to scan or open files in the folder
an agent pane is working in, and an agent pane is exactly the one that cannot
give up its terminal. `rt runner` is a board for dev servers that has to live
somewhere, and a herdr tab spent on it is a tab of chrome.

flock can host a terminal anywhere in its window, so these become things a pane
opens rather than things a pane becomes.

## What exists today

- **The `rt cd` launcher button** (shipped, PR #1). A pristine pane offers rt's
  badge plus `cd` ahead of the harness buttons. It types `rt cd`, and
  `PaneLauncherRegistry` hands the launcher back once `pane.process_info` shows
  only the shell in the foreground (`PaneForegroundJob`). This design reuses
  that check.
- **The chat button** in each pane's title row: a quiet square at rest, an
  accent pill with a count when there is something to see.
- **One surface per pane**, attached through the bridge (`herdr terminal session
  control --takeover`), sized by flock. flock already renders a tab's panes from
  its layout.
- **rt inside herdr.**
  - `rt run --resolve-only` prints a `RunResolveResult` (`targetDir`,
    `commandTemplate`, labels) on stdout, its picker on the terminal. Two rows
    launch things themselves instead: "Launch all" (in herdr, it runs the first
    queued script in its own pane and places the rest beside it, as splits, or
    as new tabs in the same workspace once the pane is under 100 by 28) and a
    saved preset (it opens a seeded, tmux-backed runner board in its own pane).
    A pick rt launched itself exits 0 with nothing on stdout; a cancelled pick
    and rt's own errors both exit 1.
  - `rt nav` prints the chosen folder on stdout when "cd here" is picked, and
    nothing when it quits; rt's `rt()` shell function is what turns that into a
    `cd`.
  - `rt runner --herdr` runs its services as panes on the rt daemon's
    background herdr server (started with `nohup`, so it outlives daemon
    restarts). Its focus key asks the daemon to open a tab in the board's own
    workspace running `herdr terminal attach <terminal> --takeover`, created
    with `--focus`. `q` and `ctrl+c` both quit the board; with services running
    either one opens a confirm that takes `y`. Quitting, SIGINT, SIGTERM and
    SIGHUP all tear its services down.
- **herdr.** `tab.create` and `workspace.create` take `cwd`, `focus`, `label`
  and `env`; `pane.split` takes `cwd`. A pane that moves across workspaces gets
  a new pane id, but keeps its terminal: `terminal_id` is stable for the pane's
  whole life.

## Availability

Every surface in this design renders only when `rt` resolves on flock's startup
PATH (`ToolPath.resolved`), the same test as the `rt cd` button. With no rt:
no rt button, no runner button, no menu. flock-owned workspaces already in
herdr are still reconciled (below), since what they run does not depend on
flock seeing rt.

## Architecture

### Where the terminals live

Every terminal this design opens is a herdr pane in a workspace flock owns,
never a PTY of flock's own. Two reasons: a runner's services must survive flock
quitting, the Restart pill and Sparkle updates, which only a herdr-owned process
does; and rt behaves natively in a herdr pane (`HERDR_PANE_ID` and
`HERDR_WORKSPACE_ID` are set), which the runner's focus key and rt run's
"Launch all" depend on. A flock-local PTY would also need a second surface
path, and libghostty wraps every command it spawns in `/usr/bin/login`.

- **`flock:rt`**: one shared workspace. Each nav, glitter or rt run gets its
  **own tab** in it, and the modal shows that whole tab.
- **`flock:rt runner <terminal>`**: one workspace per runner, its board in the
  first tab. Its own workspace because the daemon opens the focus tab in the
  board's workspace, and a shared one could not say which runner a new tab
  belongs to.

Everything is created with `focus: false` and the linked pane's cwd. When herdr
closes `flock:rt` with its last tab, flock creates it again on the next open.

**Links key on the linked pane's `terminal_id`**, never its pane id, so a pane
dragged to another workspace keeps its runner and items, whether or not flock
was running when it moved. flock decodes `terminal_id` from herdr's pane
records. Tab labels in `flock:rt` read `<kind> <terminal> <token>`
(`run term_18c2f0a1 3f2a`); a runner's workspace label carries its terminal.
`<token>` names the tab's files (below).

**Flock-owned workspaces are invisible everywhere a workspace is shown:** the
rail, the All Workspaces grid, drag and drop targets, attention toasts, herd
counts, and workspace switching. One predicate on the workspace label decides
it, and every workspace-facing surface goes through it. The herdr TUI still
lists them; that is accepted.

**Focus never follows into them.** flock's selected tab follows herdr's focused
tab. A focus change that lands in a flock-owned workspace is not followed: the
canvas stays where it was, and herdr's focus is handed back to the linked pane.
A runner's focus tab arriving this way is what opens the service view (below).

### One lifecycle

Every command runs the same way:

1. **Open.** Create the tab (or the runner's workspace) with `env` naming two
   files under flock's temporary directory, both named by the tab's token:
   `FLOCK_RT_OUT` and `FLOCK_RT_STATUS`. One `pane.process_info` call learns the
   shell (`$status` for fish, `$?` otherwise). flock then types
   `command rt <args> [>"$FLOCK_RT_OUT"]; echo $? >"$FLOCK_RT_STATUS"` with
   `pane.send_input` (text plus an `Enter` key, never a newline in the text) and
   shows the tab in the modal. `command` skips any `rt()` shell function, so the
   result lands in the file rather than in a `cd`. The typed line is visible in
   the modal until the command takes the screen; that is accepted.
2. **Watch.** Poll `pane.process_info` (300 ms) through `PaneForegroundJob` for
   every pane in the tab: busy while anything but the shell holds a foreground.
3. **Finish.** Once every pane in the tab is idle, read `FLOCK_RT_STATUS` and
   `FLOCK_RT_OUT`. A status of 0 or 130 is a clean exit. What follows is per
   command, below.

Both files are deleted before each command is typed, so a status or result
read later always belongs to the command just typed.

A command never seen busy counts as finished after 3 s, as in the launcher. A
missing status file (the shell never got that far) counts as unclean.

When a command exits uncleanly and the modal would otherwise close, it stays
open on an **exited** strip ("exited 1 · any key closes") so rt's message can be
read. Keys go to the strip, not the shell beneath. A tab's files are deleted
when the tab closes.

### Per command

| Command | Finishes when | Clean | Unclean |
|---|---|---|---|
| `rt nav` | nav quits | Tab closes. If `FLOCK_RT_OUT` holds a folder, "cd here" was picked: see below. | Exited strip. |
| `rt glitter` | glitter quits | Tab closes. | Exited strip. |
| `rt run` | picking ends, then the script ends | See below. | See below. |
| `rt runner --herdr` | the board quits | Its workspace closes; the runner button goes. | Exited strip (no daemon, say), then the workspace closes. |

**nav's "cd here":** when the linked pane is idle at a prompt, flock types
`cd <path>` into it, shell-quoted. When it is busy (an agent running), flock
splits it with `cwd: <path>` instead and focuses the new pane.

**`rt run`** runs in two phases, so flock knows which one it is in:

1. flock types `command rt run --resolve-only >"$FLOCK_RT_OUT"` (with the status
   suffix) into the tab's first pane. Phase 1 ends when **that pane** is idle
   and `FLOCK_RT_STATUS` exists; other panes in the tab do not count. Then:
   - **A result in `FLOCK_RT_OUT`:** go to phase 2.
   - **Status 0, no result:** the pick was "Launch all" or a preset, and rt
     launched it itself. The item carries on as the rest of the lifecycle
     describes: running while any pane in it is busy.
   - **Any other status, no result:** a cancel. The modal closes. rt exits 1
     for its own errors too ("No scripts found"), so in v1 those also close the
     modal without the message; see Out of scope.

   A tab that appears in `flock:rt` without a flock label is one rt placed for
   "Launch all". It joins the rt run item on screen in the modal: flock labels
   it with that item's terminal and token, the modal shows the item's tabs
   behind a small tab strip, and it is shut down and re-adopted with the item.
2. flock types `cd <targetDir> && <commandTemplate>` (shell-quoted, with the
   status suffix) into the same pane, after deleting phase 1's status file. The script's end is the next idle. The
   modal shows a **finished** strip with the exit status ("finished · exit 0 ·
   any key closes").

Without the phases, the moment between rt exiting and the script starting would
read as finished.

### Closing a modal early

- **nav, glitter:** closing the modal before the command ends (⌘W, a click
  outside, the close control, or opening another modal) shuts it down: `ctrl+c`
  with `pane.send_keys`, then the tab closes. Nothing to come back to.
- **rt run:** closing while anything in its tab is busy (the picker, the script,
  a "Launch all" split, a preset's board) keeps the tab as one of the pane's
  **rt run items**, counted on the rt button and listed in its menu. Clicking one
  reopens the modal on its tab, live. Closing a finished item's modal closes its
  tab.
- **runner:** closing hides it. Nothing stops.

### The runner

- **Start:** rt menu, **runner**. flock creates the runner's workspace, types
  `command rt runner --herdr` (with the status suffix), and opens the board in
  the modal. One runner per pane; once one exists, the menu item reads **Show
  runner**.
- **Hiding:** ⌘W or a click outside. **Showing:** the runner button, or **Show
  runner**.
- **Focus a service** (`f` in the board): the daemon creates an attach tab in
  the runner's workspace with `--focus`. flock declines to follow it, and the
  modal switches to that tab: the service's live terminal. The title row gains
  **← runner**, which closes every attach tab in the runner's workspace
  (detaching; the services run on) and returns to the board.
- **Ending:** `q` in the board (rt confirms when services are running). The
  board tears its services down and exits; flock closes the runner's workspace.

### Linked things die with their pane

When a linked pane closes, however it closes (flock, the herdr TUI, `exit`),
everything linked to its terminal is shut down: its runner, its rt run items,
and an open modal. There is no extra prompt.

Shutdown is clean, not a bare close. For each busy pane (for a runner, the
board pane in its first tab, never an attach tab):

1. `ctrl+c` with `pane.send_keys`. It stops a script, and it asks an rt board to
   quit.
2. If rt's own UI (`rt-ui`, per `process_info`) still holds the foreground a
   second later, it is on a confirm (a runner's board, or a preset's board in an
   rt run item, with services running), and flock sends `y`. flock never sends
   `y` to anything else, where it could answer some other program's prompt.

The board then tears its services down and exits. flock waits up to 10 s for
everything to go idle and closes the tab or workspace. SIGHUP from the close is
the backstop, not the plan.

### After a flock restart

At launch flock rebuilds its links from the labels:

- **Runners** whose linked terminal still exists and whose board is still
  running (no status file yet) are re-adopted: the runner button returns. A
  runner whose board exited while flock was down is closed.
- **rt run tabs** are re-adopted as items: running if any pane is busy,
  finished otherwise, their text read back from `FLOCK_RT_OUT` and the panes.
  The files say which phase an item is in (no status yet and no result: phase
  1; a result: phase 2), and the watch carries on from there, so a phase 1 pick
  finished after the restart still goes on to phase 2.
- **nav and glitter tabs** are shut down: they only exist inside a modal, and
  there is none to return to.
- **Anything whose linked terminal is gone** (its pane closed while flock was
  not running) gets the shutdown above.
- **Unlabelled tabs in `flock:rt`** (placed by rt while flock was not there to
  claim them) get the shutdown above too.

## Surfaces

Designs: `docs/design/rt/` (`flock-rt.pen` is the source). A design canvas and
reference PNGs, dark and light, are approved before any UI code, as for every
flock surface. Sizes below are starting points for that canvas.

### The rt button

In each pane's title row, **right of the chat button**, the same size.

- **At rest:** rt's badge (pink `rt` on plum) on the quiet square, like
  signed-out chat.
- **Active:** the selection pill with the badge and a count, like signed-in chat
  with unread. Active while the pane has a live runner or running rt run items;
  the count is running rt run items, plus one for a live runner.

Clicking it opens a native menu:

- **nav**: browse files here
- **glitter**: git status
- **run**: run a script…
- **runner** / **Show runner**
- a divider, then the pane's rt run items (`pnpm test · running`,
  `pnpm build · finished`)

### The runner button

Right of the rt button, only while the pane has a runner, always in the active
style. Clicking it shows the runner. v1 says "a runner is alive", not
per-service health: the services live on the daemon's background herdr server,
which flock does not connect to.

### The modal

- An overlay inside the window, never a separate panel: a panel would take key
  window from the main one, which is why Herdglass draws its overlays inside the
  window too. Centered over the whole canvas, about 80% of the window, backdrop
  dimmed.
- It shows one tab, laid out as herdr has it: usually a single pane, several
  when rt split it, and a small tab strip when an rt run item spans tabs.
- A title row: the command and folder (`nav · ~/src/acme`), a close control, and
  **← runner** when showing a service.
- One modal at a time. Opening another closes the current one by the rules in
  "Closing a modal early".
- The modal's focused surface takes the keyboard. Closing hands focus back to
  the linked pane.
- Esc belongs to the terminal (nav and glitter quit on it). The modal closes on
  ⌘W, a click outside, the close control, or its command finishing.
- Its panes are sized to the modal, the way canvas panes are sized.

## Errors

- A herdr request that fails (create, split, send) raises a flock toast naming
  what failed, and nothing is left half-open: a tab or workspace created before
  the failure is closed.
- A command that exits uncleanly is covered by the **exited** strip, except rt
  run's phase 1 (above).
- A pane whose `process_info` stops answering is treated as gone: its watch
  ends, and a modal on it closes.

## Testing

- **FlockCore, pure and hermetic** (no test spawns rt or herdr):
  - the flock-owned predicate over workspace labels, and link labels parsed and
    written;
  - links keyed by terminal id surviving a pane move;
  - the lifecycle as a state machine per command (open, busy, idle, clean,
    unclean, missing status file, the 3 s ceiling), including a multi-pane tab;
  - the typed line per shell (`$?` versus `$status`) and its quoting;
  - rt run's phase 1 outcomes: a result, a self-launch ("Launch all", preset),
    a cancel, a one-item "Launch all" whose script has not started yet, and an
    unlabelled tab joining the item on screen;
  - nav's "cd here" decision over idle and busy;
  - closing early per command; the rt button's appearance and count;
  - focus-follow declining flock-owned workspaces;
  - shutdown ordering (`ctrl+c`, `y` only when `rt-ui` still holds the
    foreground, wait, close, timeout);
  - launch reconciliation over a snapshot with re-adoptable runners, a runner
    whose board exited, rt run items in each phase, stale nav tabs, unlabelled
    tabs, and orphans. Fixture terminal ids use herdr's real `term_...` shape.
- **SessionViewModel over a stub client** that answers from scripts, as the
  launcher's tests do: `process_info`, `tab.create`, `workspace.create`,
  `pane.split`, `pane.send_input`, `pane.send_keys`, `pane.focus`,
  `pane.close`, `tab.close` and `workspace.close`. File reads go through an
  injected reader.
- **Render tests**, dark and light: the rt button at rest and active, the runner
  button, the modal with each strip, a multi-pane tab, the service view's title
  row. Compared against the canvas PNGs.
- **By hand**, since clicks and focus count as verified only then: every row of
  the per-command table, "Launch all" and a preset from the rt run modal,
  closing a pane with a live runner, dragging a pane with a runner to another
  workspace, and a flock restart with a runner and an rt run item running.

## Out of scope

- **rt run's own early errors** close the modal like a cancel, since rt exits 1
  for both. The follow-up is on rt's side: exit 130 on a cancelled pick, as its
  other pickers do; flock's clean-exit rule already treats 130 as a cancel.
- **Keyboard shortcuts** for the menu items. Added once it is clear which ones
  get used.
- **Per-service health** on the runner button.
- **rt changes.** Everything here uses rt as it ships.
- **The tmux backend** for flock's runners. flock always passes `--herdr`. (A
  preset picked in the rt run modal still opens rt's own tmux-backed board in
  that tab; it is an rt run item like any other.)
- **A docked runner panel.** The runner is a modal like everything else; its
  status lives on its button.
