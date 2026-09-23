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
  only the shell in the foreground (`PaneForegroundJob`). This design reuses that
  check for every command below.
- **The chat button** in each pane's title row: a quiet square at rest, an
  accent pill with a count when there is something to see.
- **One surface per pane**, attached through the bridge (`herdr terminal session
  control --takeover`), sized by flock.
- **rt inside herdr.** `rt run` resolves to a command with `--resolve-only`
  (`RunResolveResult`: `targetDir`, `commandTemplate`, labels). `rt runner
  --herdr` runs its services as panes on the rt daemon's background herdr server
  (started with `nohup`, so it outlives daemon restarts), and its focus key asks
  the daemon to open a tab in the board's own workspace running `herdr terminal
  attach <terminal> --takeover`, created with `--focus`. The board tears its
  services down on SIGINT, SIGTERM and SIGHUP.

## Availability

Every surface in this design renders only when `rt` resolves on flock's startup
PATH (`ToolPath.resolved`), the same test as the `rt cd` button. With no rt:
no rt button, no runner button, no menu. Hidden workspaces already in herdr are
still reconciled (below), since what they run does not depend on flock seeing
rt.

## Architecture

### Where the terminals live

Every terminal this design opens is a herdr pane in a workspace flock owns,
never a PTY of flock's own. Two reasons: a runner's services must survive flock
quitting, the Restart pill and Sparkle updates, which only a herdr-owned process
does; and rt behaves natively in a herdr pane (`HERDR_PANE_ID` and
`HERDR_WORKSPACE_ID` are set), which is what `rt run` and the runner's focus key
depend on. A flock-local PTY would also need a second surface path, and
libghostty wraps every command it spawns in `/usr/bin/login`.

- **`flock:rt`**: one shared workspace for modal commands (nav, glitter, run).
- **`flock:rt runner <pane>`**: one workspace per runner. Its own workspace,
  because the daemon opens the focus tab in the board's workspace, and a shared
  one could not say which runner a new tab belongs to.

Both are created with `focus: false` and the linked pane's cwd. Modal panes are
labelled `<kind> <pane>` (`nav w1:p2`), so the link survives flock restarts in
herdr's own state.

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

1. **Open.** Create a pane in the command's workspace at the linked pane's cwd,
   type the command with `pane.send_input` (text plus an `Enter` key, never a
   newline in the text), and show the pane in the modal.
2. **Watch.** Poll `pane.process_info` (300 ms) through `PaneForegroundJob`:
   busy while anything but the shell holds the foreground. The idle answer
   carries the shell's `cwd`, which is how nav's "cd here" is read.
3. **Finish.** Per command, below.

A command that is never seen busy counts as finished after 3 s, as in the
launcher.

**Output left behind keeps the modal open.** When a command finishes and its
pane's screen holds more than the two prompts a clean exit leaves (the prompt it
was typed at, and the new one), it printed something: an error (no daemon, no
git repo) or a message. The modal then stays on an **exited** strip ("exited ·
any key closes") instead of closing, so it can be read. The prompt's height is
the row count the pane settled at before the command was typed, the same
measurement the launcher makes. A quick Esc out of nav leaves two prompts and
closes as normal.

### Per command

| Command | Opened from | Finishes when | Then |
|---|---|---|---|
| `rt nav` | rt menu | nav quits | Modal and pane close. If the shell's cwd moved, "cd here" was chosen: see below. |
| `rt glitter` | rt menu | glitter quits | Modal and pane close. |
| `rt run` | rt menu | picking ends, then the script ends | See below. |
| `rt runner --herdr` | rt menu | `q` in the board | Its workspace closes; the runner button goes. |

**nav's "cd here":** when the linked pane is idle at a prompt, flock types
`cd <path>` into it, shell-quoted. When it is busy (an agent running), flock splits it with
`cwd: <path>` instead and focuses the new pane.

**`rt run`** runs in two phases, so flock always knows which one it is in:

1. flock types `rt run --resolve-only > <file>` (a file under flock's temporary
   directory). The picker runs; when the pane goes idle, flock reads the
   `RunResolveResult` from the file. An empty or unreadable file means the pick
   was cancelled: the modal closes.
2. flock types `cd '<targetDir>' && <commandTemplate>` into the same pane. The
   script's end is the second idle. The modal then shows a **finished** strip
   ("finished · any key closes"); keys go to the strip, not the shell beneath.

Without the split, the idle moment between rt exiting and the script starting
would read as finished.

Closing the modal while the script runs keeps it running: it becomes one of
the pane's **rt run items**, counted on the rt button and listed in its menu.
Clicking one reopens the modal on its pane, live. An item leaves the list when
its modal is closed after it finished.

### The runner

- **Start:** rt menu, **runner**. flock creates the runner's workspace, types
  `rt runner --herdr`, and opens the board in the modal. One runner per pane;
  once one exists, the menu item reads **Show runner**.
- **Hiding:** ⌘W or a click outside hides the modal. Nothing stops.
- **Showing:** the runner button, or **Show runner**.
- **Focus a service** (`f` in the board): the daemon creates the attach tab in
  the runner's workspace with `--focus`. flock declines to follow it, and the
  modal switches to that tab's pane: the service's live terminal. The title row
  gains **← runner**, which closes the attach tab (detaching; the service runs
  on) and returns to the board.
- **Ending:** `q` in the board (rt confirms when services are running). The
  board tears its services down and exits; flock closes the runner's workspace.

### Linked things die with their pane

When a linked pane closes, however it closes (flock, the herdr TUI, `exit`),
everything linked to it is shut down: its runner, its rt run items, and an open
modal. There is no extra prompt.

Shutdown is clean, not a bare close: flock sends `ctrl+c` with
`pane.send_keys` (the same call rt's runner uses to stop a service), which
triggers the board's own teardown or stops the script, waits up to 10 s for the
pane to go idle, then closes the pane or workspace. SIGHUP from the close is the
backstop, not the plan.

**At launch,** flock reconciles: a flock-owned pane or workspace whose linked
pane no longer exists (closed while flock was not running) gets the same
shutdown.

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
  window too. Centered over the whole canvas, about 80% of the window,
  backdrop dimmed.
- A title row: the command and folder (`nav · ~/src/acme`), a close control, and
  **← runner** when showing a service.
- One modal at a time. Opening another hides the current one (a running thing
  keeps running).
- The modal's surface takes the keyboard. Closing hands focus back to the
  linked pane.
- Esc belongs to the terminal (nav and glitter quit on it). The modal closes on
  ⌘W, a click outside, the close control, or its command finishing.
- Its pane is sized to the modal, the way canvas panes are sized.

## Errors

- A herdr request that fails (workspace create, split, send) raises a flock
  toast naming what failed, and nothing is left half-open: a pane created before
  the failure is closed.
- A command that fails and prints why is covered by the **exited** strip.
- A runner started while the rt daemon is down exits with rt's own message; the
  exited strip keeps it readable.
- A pane whose `process_info` stops answering is treated as gone: its watch
  ends, and a modal on it closes.

## Testing

- **FlockCore, pure and hermetic** (no test spawns rt or herdr): the
  flock-owned predicate over workspace labels; link labels parsed and written;
  the lifecycle as a state machine per command (open, busy, idle, finished,
  exited, the 3 s ceiling); the output-left-behind rule over row counts, with a
  multi-line prompt; the two-phase `rt run` including a cancelled pick;
  nav's "cd here" decision over idle/busy; the rt button's appearance and count;
  focus-follow declining flock-owned workspaces; shutdown ordering (ctrl+c, wait,
  close, timeout); launch reconciliation over a snapshot with orphans.
- **SessionViewModel over a stub client** that answers `process_info`,
  `workspace.create`, `pane.split` and `pane.send_keys` from scripts, as the
  launcher's tests do.
- **Render tests**, dark and light: the rt button at rest and active, the runner
  button, the modal with each strip, the service view's title row. Compared
  against the canvas PNGs.
- **By hand**, since clicks and focus count as verified only then: every row of
  the per-command table, closing a pane with a live runner, and a flock restart
  with a runner running.

## Out of scope

- **Keyboard shortcuts** for the menu items. Added once it is clear which ones
  get used.
- **Per-service health** on the runner button.
- **rt changes.** Everything here uses rt as it ships.
- **The tmux backend** for flock's runners. flock always passes `--herdr`.
- **A docked runner panel.** The runner is a modal like everything else; its
  status lives on its button.
