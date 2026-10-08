# Pane launcher at an empty prompt

## Goal

The harness launcher (the monogram buttons a new pane shows) is offered
whenever a pane's shell sits at an empty prompt, and goes away whenever it
does not. Today it is offered from a pane's history: pristine until the first
keystroke or output, re-opened only by a Ctrl-L watch window or by the
launcher's own `rt cd`. That model has three standing defects:

- ⌘1..⌘3 do not reach the Launch items. Their key equivalents are attached
  only while the focused pane is pristine and otherwise sit on the View
  items, which relies on the menu bar re-rendering the instant a pane turns
  pristine. The launcher log category, written on every press that arrives,
  is empty for the last fourteen days while other categories log hundreds of
  lines a day.
- The launcher does not reliably return after `rt cd`. The return rides a
  poll of `pane.process_info`, and one answer flock cannot read (a socket
  error, or herdr's empty foreground list as the picker exits) ends the watch
  for the session. The return also needs a pane flock created or cleared
  with Ctrl-L this session, so after a Flock restart nothing qualifies.
- Typing `clear`, a program leaving an empty screen, and a restart never
  bring it back, because nothing asks "is this pane empty now".

Success: a fresh pane, a pane after Ctrl-L or `clear`, a pane after `rt cd`,
and a pane seen for the first time after a Flock restart all show the
launcher within a second of the shell being idle at a bare prompt; it hides
on the first keystroke or output; ⌘1..⌘3 launch into a pane showing the
launcher from a cold app launch without any menu having been opened; a click,
a ⌘ digit and a palette row on the same button do the same thing; and every
press writes one log line.

## Visibility rule

Each pane with a live, unparked surface carries four things:

- `promptRows`: the non-empty row count of a bare prompt, or unknown.
- `rows`: the latest non-empty row count of the active screen.
- `typed`: whether a keystroke has gone into the pane since it was last bare.
- `idle`: herdr's latest answer on whether the shell holds the foreground,
  valid only since the screen last changed.

The launcher shows when all three hold: `rows <= promptRows`, `typed` is
false, and `idle` is a fresh true. It is per pane: several panes may show it
at once; ⌘ digits target the canvas's focused pane.

### Learning the prompt height

A learning window of two seconds opens:

- at the pane's first frame;
- at any drop in `rows` that lands at or below the current `promptRows` (a
  clear landing);
- when a launcher-run navigator ends (see "Navigator").

While a window is open, every report sets `promptRows` to the count seen, so
a prompt painted over two frames, or starship's two startup warnings, count
as the prompt. A keystroke closes the window early: `clear` followed by `ls`
cannot teach the pane that `ls` output is a prompt.

The first report decides whether a window opens at all: at or below a cap of
four rows it is a prompt coming up (a fresh pane's first frame, or a pane
first seen mid-life, after a Flock restart or made by herdr, sitting at a
bare prompt), and the window opens; above the cap it is content, and the
pane waits for a drop. Four clears a two-line prompt plus starship's two
warnings; a two-line prompt, one line of output and a new prompt is five, so
a short command's output never passes as empty. Inside a window, a report
above eight rows (taller than any prompt) is output and closes the window
instead of teaching.

### Startup output on a pane flock created

A pane flock just created (split, new tab, new workspace) is in startup until herdr first answers idle, a key is typed, or a navigator is started from the launcher. During startup every row report is taken as the prompt height, with no cap and no window, and the pane stays a candidate, so herdr is asked with the usual backoff. The first idle answer with nothing typed ends startup and shows the launcher over whatever the shell printed on its way up: a fastfetch banner, a message of the day, a prompt of any height. An idle answer that lands before the shell finishes printing ends startup early, and a banner that follows hides the launcher until the next clear. Accepted. Provenance is only this hint about where to start; it never decides whether the launcher may show.

A pane first seen mid-life (after a Flock restart, or made outside flock) cannot be measured from the screen alone: a six-row screen may be a six-row prompt or a short prompt under output, and herdr's repaint strips the shell's prompt marks before flock sees them. It keeps the cap of four rows until its first clear, which teaches it the real height.

### Hiding and re-arming

- Any non-⌘ keystroke sets `typed`.
- `typed` clears on Ctrl-L (an explicit ask for a fresh screen), on a drop in
  `rows` to bare, and when a navigator ends.
- `rows > promptRows` hides; the next drop to bare re-arms.
- A busy shell hides while polling continues.
- Typing `ls` and erasing it with Ctrl-U leaves the launcher hidden until the
  next clear. Accepted.
- A prompt that grows after its window closes (an async segment landing
  seconds later) hides the launcher until the next clear. Accepted; it is the
  same as today.

### What goes away

Provenance as a gate ("offerable"), the pending-clear window
and its bookkeeping, and the rule that a pane stops being watched once it is
"in use". Every pane on screen plays by the same rule.

## Signals and cost

### Screen rows

The surface counts the active screen's non-empty rows on a timer: every
500ms while it is live and unparked, it reads the active screen and reports
the count only when it changed. libghostty's render action cannot drive
this on macOS: only its GTK runtime routes draws through that action, so the
embedded runtime never sends it (found by the spike; it is also why the
pre-existing Ctrl-L re-offer never worked).

- Counting runs for every live, unparked surface; the "stop reporting"
  return value and `resumeScreenActivityReporting` go.
- Parking stops the timer and unparking restarts it with an immediate read.
- Only a changed count reaches the registry.

The read covers the active screen, never the scrollback, so its cost is the
size of the window, not the session's history.

### Shell idle

`pane.process_info` is asked only while a pane is a candidate: bare rows,
`typed` false, and no idle answer since the screen last changed. The first
ask is immediate. While the answer is busy or unknown, it is asked again with
backoff: 0.5s, 1s, 2s, 4s, 8s, then every 8s, reset by any screen change,
stopped when the pane stops being a candidate or leaves the screen. An
unreadable answer (a thrown request, or herdr's empty foreground list, which
`PaneForegroundJob.isBusy` reads as nil) counts as unknown. Nothing ends a
watch except the pane going away from the model.

### Navigator

The `rt cd` slot sends the command as today, then polls every 300ms until
the command was seen running and then idle, or idle past the three-second
start ceiling. Unreadable answers are retried like busy. Then flock sends
Ctrl-L over `pane.send_keys` (`ctrl+l`; herdr rejects `C-l`), clears `typed`, and opens a learning
window. The generic rule shows the launcher when the drop lands and herdr
confirms idle. Keystrokes while the picker is up are the picker's, not the
pane's, as today.

### Keystrokes

The existing seam from `GhosttySurfaceView.keyDown` through the factory
closure. Ctrl-L is still recognized by `ClearKey`, but now only clears
`typed` and pokes an immediate re-check; the clear window is gone.

### Where it lives

`PaneLauncherRegistry` stays a pure, clock-injected state machine in
FlockCore, constructed with its poll backoff so tests can shorten it. Inputs:
`recordRows(_:rows:at:)`, `recordKeystroke(_:)`, `recordClearKey(_:)`,
`recordForegroundJob(_:idle: Bool?, at:)` (which also ends a navigation),
`recordNavigationStarted(_:at:)`, `forget(_:)`. Outputs: `isShowing(_:)`,
`isNavigating(_:)`, `nextPollDelay(_:) -> Duration?` (nil when the pane is
not a candidate, `.zero` to ask now), `occupiedRows(_:)`. `SessionViewModel`
owns one poll task per candidate pane, started and restarted from the rows
and keystroke seams the way navigation watches are owned today, and bumps
`launcherRegistryVersion` on every answer that changes `isShowing` or the
occupied rows.

## ⌘ digits and launch paths

### Binding

⌘1, ⌘2 and ⌘3 stay on the View menu's Workspaces, Overview and Arrange
items, always, never toggled. Their action asks the view model first: if the
canvas's focused pane is showing the launcher, the digit launches that slot;
otherwise it switches the view. `launcherOffered` is deleted. Slots 4 to 9
have no view counterpart and keep ⌘4..⌘9 on their Launch items. The Launch
submenu stays; its first three items show no key, while the overlay buttons
and the palette rows keep showing ⌘1..⌘3 as hints. Only a key press is
borrowed: picking Workspaces, Overview or Arrange from the menu with the
mouse always switches the view. Digit dispatch is a pure function (`showing`,
whether the action came from a key, and slot index in; `.launch` or `.view`
out) so the SwiftUI wiring stays thin.

### One launch path

A click, a ⌘ digit and a palette row all call one function. It resolves the
target pane: the pane under the button for a click, the canvas's focused pane
otherwise, and never a pane where herdr has detected an agent
(`LaunchTarget`). It asks herdr once whether the shell holds the foreground;
if not it beeps. Otherwise it sends the harness name plus Enter, or starts
the navigator flow for the `rt cd` slot. Today the click skips the herdr
check.

### Logging

Every press on every path writes one line under the launcher category:
path (click, key, palette), slot id, pane id, and herdr's answer. Read it
with `/usr/bin/log show --predicate 'subsystem == "dev.mattstack.flock" AND
category == "launcher"'`.

### Renames

`isPristineLauncherPane` on `SessionViewModel`, `PaneTerminalView` and
`GhosttySurfaceView` (where it makes the surface ignore clicks so the
SwiftUI buttons get them) and the cell's matching tap guard become
`isLauncherShowing`, fed from `PaneLauncherRegistry.isShowing`.
`PaneLoaderPolicy.showsLauncherOverlay` takes the same answer.

## Overlay placement

The overlay's top clearance follows the prompt: `occupiedRows` times the
surface's cell height, plus one row, never less than today's 28 points, and
never so much that the button row no longer fits in the pane: on a pane
shorter than its banner the buttons sit over the banner's last rows. The
`GhosttyPaneSurface` protocol gains `cellHeight: CGFloat?` (nil before the
first `GHOSTTY_ACTION_CELL_SIZE`), and the test fake returns a fixed value.
Everything else about the overlay stays: the button row, hover and press
states, the no-harness hint, the fade.

## Out of scope

Shell integration (OSC 133) and herdr-side prompt events: herdr is reference
only here and the bridge repaints herdr's screen, so prompt marks never reach
flock's libghostty. Changing which harnesses the roster offers. Launching
into agent panes.

## Testing

### Step 0: a diagnostic spike, thrown away

Before any real change, a Flock Dev build that logs, under the launcher
category: every ⌘-digit key event as it enters the app and whether the menu
bar claimed it; each row count a surface reports, per pane; herdr's answer on
every navigator poll. Matt runs a short script in it: new pane; ⌘2 before and
after opening Pane ▸ Launch once; type `ls`; Ctrl-L; type `clear`; click
rt cd and pick a folder; restart Flock Dev and look at the same pane. The log
confirms or corrects four assumptions, and the plan records the findings:
where today's presses die, that the prompt is two rows and four at startup,
what rt cd leaves on screen, and that herdr's answers stay readable through
the picker's exit. Against a scratch herdr session, `pane.send_keys` with
`ctrl+l` is confirmed to clear a zsh prompt. Nothing from the spike is kept.

### FlockCore unit tests

`PaneLauncherRegistryTests`, rewritten test-first:

- A fresh pane learns its height across the window, including a noisy
  startup, and shows once idle.
- A pane first seen mid-life learns from a report at or below the cap, and
  waits for a drop above it.
- A keystroke hides; Ctrl-L re-arms; `clear` then `ls` within the window
  does not mislearn.
- A drop to bare re-arms and re-learns; output above the height hides.
- Busy hides and schedules backoff; an unknown answer never ends a watch;
  a screen change resets the backoff.
- Navigation: picker keystrokes are ignored, idle before start is not the
  end, the ceiling, the end clears `typed` and opens a window.
- `occupiedRows` follows the latest count.

`SessionViewModelTests`:

- One poll task per candidate pane, driven by the rows seam, with the stub
  client's idle, busy and failure scripts; a failure mid-watch retries.
- The navigator sends `ctrl+l` after idle, through `pane.send_keys`.
- Click, key and palette go through the one launch function, each asking
  `pane.process_info` once; a busy answer sends nothing.
- `isLauncherShowing` bumps the observation seam when it changes.

`DigitKeyDispatchTests`: showing plus slot gives `.launch`; otherwise
`.view` for 1..3 and nothing for the rest.

### FlockChromeRender

- Overlay clearance at two and at four occupied rows, dark and light PNGs,
  looked at before done.
- The existing hit-testing cases stay green under the renamed flag.

### End to end

One new `FlockUITests` case: a fresh pane, ⌘2, the harness name arrives at
the scratch herdr pane. `Scripts/e2e.sh` launches the app, so it runs once
locally with Matt's OK; CI runs the core, render and checks suites.

### Hand-off

`Scripts/dev-build.sh --output` to the main checkout's `build/dev`, the
restart pill, and a checklist for Matt in Flock Dev: fresh pane, Ctrl-L,
`clear`, rt cd, restart, and ⌘1..⌘3 from a cold launch.
