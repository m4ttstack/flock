# Mission control and Arrange

**Goal:** the All Workspaces view gets two modes. Mission control shows, at a
glance and live, what every agent across every workspace is doing and what
needs you, so it can be left open, watched, jumped out of and come back to.
Arrange, the grid for moving panes between workspaces, is redrawn so each
workspace reads as its own place and the window is used, not left empty.

**Status:** design approved 2026-10-06. flock only. Visual references in
`docs/design/workspaces/flock-workspaces.pen`: board `05 · MC · Lanes`
(mission control), board `10 · Arrange · Islands` sized as board
`08 · Arrange · fit to window` sizes it (Arrange).

## Why

The All Workspaces grid is good at one job: arranging, pulling panes that
landed in the wrong workspace back where they belong. As an overview it is a
flat wall of thumbnails. Every pane gets the same box whether it is blocked,
busy or untouched since yesterday, so finding what matters means scanning all
of it. Mission control answers a different question, "what is happening and
what needs me", and leaves quiet panes out of the way.

Arrange keeps its job but fails at it visually. A workspace, a tab and a pane
are all the same dark box with the same 1pt outline, so nothing separates one
workspace from the next and the view reads as one field of similar
rectangles. Cards are half the window whatever they hold, thumbnails are a
fixed 120pt, and on a large window most of the view is empty.

## What exists today

Mission control reads these; it replaces none of them.

| Piece | What it gives | Where |
|---|---|---|
| All Workspaces grid | the view, its open/close state, Esc routing | `AllWorkspacesGrid` (both targets), `AllWorkspacesGridState` |
| Attention stack | the "needs input" and "finished" cards, their rules and lifetime | `AttentionToastStack`, `NotificationLifetime`, `SessionViewModel.withdrawSettledAttentionToasts` |
| ⌘J | jump to the oldest card the dock draws, dismissing it | `SessionViewModel.jumpToOldestDisplayedAttentionToast` |
| ⇧⌘J | Clear Notifications | `ViewCommand.clearNotifications` |
| ⇧⌘R | All Workspaces | `ArrangeShortcut.allWorkspaces` |
| Agent status | per pane, with change events | `PaneRecord.agentStatus`, `HerdrEvent.paneAgentStatusChanged` |
| Pane title | the name or the agent's current task | `PaneRecord.displayTitle` |
| Rail order and sections | workspaces, board, herds | `RailSections` |
| Herd progress | done / total workers | `HerdProgress`, `HerdRail` |
| Main checkout | a folder's repository from git's files | `MainCheckout` |

## Behaviour

### Modes

The All Workspaces view has two modes,
**Overview** and **Arrange** (Overview is mission control; the code keeps that name), chosen from the title bar's view tabs (below). The view remembers the mode last used across launches, and ⇧⌘R opens it in that mode.

Mission control has no drag sources and is never a drop target: a drag starts
only in Arrange or the main window, so the drop surface is always Arrange.

### View tabs

Board `12 · View tabs in the title bar`. Flock has three peer views:
**Workspaces** (the main window: rail, tab strip, canvas), **Overview** and
**Arrange**. Tabs in the title bar switch between them, styled like the
Mattstack viewer's.

- The title bar grows to 36pt. The tabs sit right after the traffic
  lights, each a small glyph and a label: Workspaces (a split), Overview
  (three lanes), Arrange (a 2×2 grid). The selected tab takes the
  tab-strip fill, an accent glyph, strong text and a 2pt accent underline;
  the others are dim, with the grid controls' hover and press. "flock" and
  the dev tag stay centred and hide before they would overlap the tabs;
  the right side keeps the restart pill and connection notice, and shows
  `⌥⌘1 ⌥⌘2 ⌥⌘3`.
- The tabs replace the Overview | Arrange toggle in the grid header. The
  header keeps the workspace count and the key hints.
- **Keys**: ⌥⌘1 Workspaces, ⌥⌘2 Overview, ⌥⌘3 Arrange, in the View menu and
  the palette. ⇧⌘R still toggles between Workspaces and the grid view used
  last. Esc from Overview or Arrange still returns to Workspaces; inside a
  focused pane Esc still belongs to the terminal.
- The selected tab is derived, not stored: Workspaces while the grid is
  closed, otherwise the mode drawn (a live drag still forces Arrange).
- A focused pane belongs to Overview: Overview's tab stays selected, and
  its back button stays the way out. Choosing Arrange (tab or key) leaves
  the focused pane. Choosing Overview while focused changes nothing.
- During a drag the tabs are drawn but inert.
- The rail's All Workspaces button (the 2×2 grid glyph in the workspace
  list's header) is removed: the tabs are the way in.

### Lanes

Three equal columns, each scrolling on its own. Every pane that is not
dormant appears in exactly one lane, decided in this order:

1. **Needs you**: the pane has a card in the attention stack. The lane IS the
   stack: same cards, same raising, coalescing, lifetime and withdrawal rules,
   so the dock and the lane can never disagree. Ordered oldest first.
2. **Working**: the pane's status is `working`. Ordered by rail order
   (workspaces, then board, then herds), then by tab and pane order inside a
   workspace. A small workspace label sits above the first card of each
   workspace, so a workspace's agents stay together.
3. **Cooling down**: anything else whose last status change is within the
   dormant cutoff. Most recent change first. Cards draw at reduced opacity.
4. **Dormant**: anything else. Not drawn as cards. The foot of Cooling down
   holds one line, "N dormant", that expands in place to a compact list (dot,
   workspace › tab, title) and collapses again. A dormant pane moves to its
   lane the moment its status changes.

A blocked or done pane whose card was cleared (⇧⌘U, or a "finished" card
that timed out) is not in Needs you; it falls to Cooling down, then Dormant.

Each lane's header shows its status dot, its name and its count. An empty
Needs you lane reads "Nothing needs you".

### A card

Top line: status dot, `workspace › tab` (a herd's workspace reads `auth
sweep · herd 2/4`), and at the right the state and its age in the terminal
face, `working 18m`, in the status hue. The workspace name draws in the
workspace's identity colour (see Identity colour). In Working the workspace label above
the group already names it, so the top line there is the tab alone.

Title: the pane's `displayTitle`, wrapped to at most two lines.

Bottom line: `repo @ branch` in the terminal face, and at the right a
timeline of the last 60 minutes: working, blocked and done as solid
segments in their hues, idle as a thin line, time with no record as the
track alone.

A blocked card carries a 1.5pt outline in the blocked hue.

**Identity grouping** (board `05c · Overview · identity groups`). Overview
wears Arrange's colours so the two read as one place:

- In Working, each workspace's cards sit in a group on its identity tint,
  the same colour and strength as its Arrange island (radius 10, 10pt
  padding, 10pt between cards). The group label is the identity square and
  the workspace name in its identity colour; no rule.
- In Needs you and Cooling down, a card's top line leads with the identity
  square, then the status dot, then the workspace name in its identity
  colour and `› tab` in the label colour.
- Status keeps its own colours: dots, ages, the blocked outline and the
  timeline stay in status hues, and identity never fills a card.
- A herd's group and name draw in the neutral label grey, as in Arrange.

### Live updates

While shown, the view follows the model as it changes. A card whose lane
changes moves to its new place with a short ease (no bounce); with Reduce
Motion on it appears there without moving. Ages and timelines refresh once a
minute, not continuously.

### Keys and jumping

- **⌘J** is unchanged in meaning everywhere: jump to the oldest attention
  card, dismissing it. In mission control every card is drawn, so it is the
  top card of Needs you.
- **Clicking a card**, or Return on the selected card, opens that pane in
  the focused view (below). A Needs-you card is dismissed by opening it,
  exactly as a dock card is by a jump.
- **⇧⌘J, Jump Back** (new, View menu and palette): returns to where the last
  jump started. A jump is ⌘J, a dock card click, or a mission-control card
  activation. Its origin is mission control when the jump left from there
  (reopened with the same card selected and scrolled into view), otherwise the pane
  that was focused. Jump Back records where it left from as the new origin,
  so pressing it again goes forward: it toggles between two places. One
  level only. Disabled when there is no origin or the origin pane has closed.
- **⇧⌘U, Clear Notifications** moves here from ⇧⌘J.
- **Arrows** move a selection ring between cards (up and down inside a lane,
  left and right across lanes, keeping the nearest row). The first open
  selects the top card of the first non-empty lane. **Esc** closes the view.

The header's right side shows the keys: `⌘J oldest · ⇧⌘J back · esc`.

### Focused pane

Board `11 · Overview · Focused pane`. Opening a card from Overview shows
that one pane, live, inside the All Workspaces view, with going back to
Overview as the only way to navigate. A jump from Overview no longer lands
in the main window, which had no visible way back.

**Opening.** A card click or Return, and ⌘J while Overview is shown (the
oldest card), open the pane here. A Needs-you card is dismissed on opening.
⌘J and dock clicks from the main window jump in the main window as before.

**What it draws.**

- A header the grid header's height:
  - left: a "‹ Overview" button, then the identity square, `workspace ›
    tab` (workspace in its identity colour), the status dot and the state
    with its age (`blocked 12m`) in the status hue;
  - right: "N more need you" while other Needs-you cards remain, then
    `⌘J next · ⇧⌘J overview`.
- Below it, the pane exactly as the main window's canvas draws it,
  filling the space: its terminal, title and status chip, and its
  top-right legend controls (mouse badge, chat button, rt button). Typing
  goes to it. The rt modal and the chat popover open from it as they do
  in the main window. The zoom badge is not shown: there is no zoom here
  to leave.
- No tab strip, rail or dock, so nothing reads as navigation but the back
  button.

**Keys.**

- ⇧⌘J or "‹ Overview" returns to Overview with this pane's card selected
  and scrolled into view.
- ⌘J swaps in the next oldest Needs-you card, staying in the focused view;
  disabled when none remain.
- Esc and every other key go to the terminal; nothing here navigates on
  Esc.

**herdr is not moved.** Opening, swapping and returning never focus a tab
or pane in herdr, and a click on the pane's title only gives its terminal
the keyboard. Leaving Overview (Esc there) returns the main window exactly
as it was.

**Sizing.** The pane fills the view at the Terminal Text size; its PTY is
resized to fit, as a window resize would, and resized back when the main
window shows it again.

**Edge cases.** If the pane closes while focused, the view returns to
Overview. Its header follows status changes live. The focused view has no
drag sources and is never a drop target.

**Built from the main window's pieces.** The pane is the canvas's own
`PaneCellView` inside `PaneCanvas`, shown through the canvas's existing
`CanvasComposition.zoomed` with the badge and herdr focusing turned off,
not a second terminal view. Which pane is focused, and the open, next and
back rules, live in FlockCore beside the mode store and are unit tested.

### Arrange

Arrange keeps every behaviour the grid has today: drops into a tab or a pane
position, drops on a workspace's empty space create a tab, tab reorder inside
a workspace, click to preview a pane, double-click to go there, spring-load
on dwell. What changes is how it draws.

**Islands.** Each workspace is a region filled with its identity colour at
low strength (about 10 percent over the canvas), corner radius 14, with no
outline. The workspace you came from adds a 1.5pt outline in its identity
colour. Islands sit 28pt apart; inside one, tabs sit 8pt apart, so the gap
between workspaces is always clearly wider than the gap within one.

**Island header.** Identity square (12pt, radius 3), the workspace name at
16pt semibold (emoji included), its status dot, and the tab count at the
right.

**Thumbnails.** No outline. A thumbnail is a `pane`-filled block; its handle
is the tab title and status dot on no fill, except the tab you came from,
whose handle takes the identity colour at about 25 percent. Mini panes are
`tabRest` blocks with the status word and the title wrapped to three lines. A
blocked mini pane keeps a 1.5pt outline in the blocked hue, the only outline
inside an island.

**Order.** Islands pack left to right in rail order (workspaces, then
board's, then herds), wrapping to a new row when the next island would not
fit. Board's islands share the board's colour and herds share one neutral
colour.

**Fit to window.** One thumbnail width is chosen for the whole view: the
largest, from 120pt up to 260pt, at which every island fits the window
without scrolling (height follows at a fixed, short ratio of 0.62). Below 120pt the view
scrolls instead of shrinking further. The size is decided when the view
opens and when the window resizes, never during a drag, so a drop target
never moves under the pointer.

**Dormant workspaces.** A workspace whose panes are all dormant (the
mission-control rule) shrinks to a chip in a DORMANT strip at the bottom:
status dot and name. A chip is a drop target: a drop on it creates a tab in
that workspace, and dwelling on it during a drag springs it open as a full
island for the rest of that drag. Clicking a chip opens its island until the
view closes.

## Data

### Status history

A new FlockCore type records, per pane, every status transition with its
time, as `paneAgentStatusChanged` and snapshots arrive, and drops entries
older than 60 minutes (keeping the transition that was in force at the
window's start). It lives in memory only: after a launch timelines start
empty and fill in. A pane first seen at launch is recorded as having entered
its current status at launch time.

It answers, for a pane: the current status's age, the timeline segments for
the last 60 minutes, and the time of the last change. It takes the clock as
a parameter so tests control time.

### Dormancy

A pane is dormant when it is not in the attention stack, its status is not
`working`, and its last status change is older than the cutoff. The cutoff is
a Settings value under Notifications, "Dormant after", one of 15, 30
(default), 60 or 120 minutes, persisted like `NotificationLifetimeStore`.

A shell with no agent never changes status, so it reads dormant once the
cutoff passes after launch even while a command runs in it. Using
`PaneForegroundJob` to keep busy shells awake is a follow-up, not part of
this work.

### Identity colour

A palette of eight hues per theme, chosen so none sits within 25 degrees of
hue of a status colour (working, blocked, done, idle) and each keeps 3:1
against the canvas for the identity square. Flock assigns the next unused hue
to a workspace the first time it sees it, keyed by workspace id so a rename
keeps the colour, and stores the assignment in UserDefaults. An island
header's right-click menu in Arrange gets Colour, which lists the eight hues
and stores an override the same way. Assignments for workspaces herdr no longer reports
are dropped whenever the view opens.

Identity colour appears in Arrange and on mission-control cards only. The
rail and the tab strip stay as they are, where colour already means status.

### Repo and branch

From the pane's `foregroundCwd`, else its `cwd`: the repository is the main
checkout's folder name (`MainCheckout`), the branch is read from the
worktree's `HEAD` file (`ref: refs/heads/<name>`; a detached head shows the
short hash). File reads only, never a git process. Cached per folder and read
again when a pane's folder changes or the view opens. A folder outside any
repository shows the folder's last path component and no branch.

## Layout and visuals

As board 05, in the minimal-chrome roles (`docs/design/colors/minimal-spec.md`):
canvas behind, lanes on `pane`, cards on `chrome` with a `rule` outline,
status hues from the theme. Lanes are equal width with a 16pt gap and 24pt
canvas padding; cards have 12 by 14pt padding, a 6pt radius and a 10pt gap.
These boards are drawn in app points (today's 120pt thumbnail measures 120
on them), so their values are used as they are, without the minimal spec's
1.28x scale.

Board 05 needs two additions before it is the reference: workspace labels in
the Working lane, and the key hints in the header. Both themes are rendered
and checked before implementation starts.

## Out of scope

- Identity colour in the rail or the tab strip.
- A separate or torn-off mission-control window.
- Recent output lines on cards (costs a `pane.read` per pane per refresh).
- Keeping status history across launches.
- Keeping busy agentless shells out of Dormant.

## Testing

FlockCore unit tests:

- the status history: recording, trimming at 60 minutes with the in-force
  entry kept, age and segment answers under an injected clock;
- lane assignment and its precedence, including a cleared blocked card and a
  pane at the cutoff's edge;
- lane ordering: oldest-first Needs you, rail-ordered Working with label
  breaks, most-recent-first Cooling down;
- Jump Back's origin rules: set by each jump kind, toggling, disabled on a
  closed origin;
- `HEAD` parsing for a branch, a detached head and a missing file;
- the dormant cutoff store's default and persistence;
- the fit-to-window size: largest width that fits, the 120pt floor, the
  260pt cap, and no change while a drag is live;
- island packing in rail order, and dormant workspaces moving to chips;
- identity assignment: stable across a rename, overrides kept, stale ids
  dropped, and no palette hue near a status hue in any builtin theme;
- the focused pane: opening from a card or ⌘J, ⌘J swapping to the next
  oldest card and disabling when none remain, back selecting the card, a
  closed pane returning to Overview, and no herdr focus call on any of them.

FlockChromeRender tests render mission control and Arrange with fixture data in a dark
and a light theme, writing PNGs under `FLOCK_GRID_RENDER_DIR`, and samples a
blocked card's outline and a lane header's dot. They also render the focused
pane (its header and its pane's legend controls) and Overview's identity
groups in both themes. The UI is looked at in both themes before it is
called done.
