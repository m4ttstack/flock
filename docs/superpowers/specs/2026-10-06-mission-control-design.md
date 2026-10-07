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
  (three lanes), Arrange (a 2×2 grid). Like the viewer's, each tab is a
  flat cell the bar's full height with square corners, ruled from its
  neighbours. The selected tab takes the tab-strip fill, an accent glyph,
  strong text and a 2pt accent underline; the others are dim, with the
  grid controls' hover and press. "flock" and
  the dev tag stay centred and hide before they would overlap the tabs;
  the right side keeps the restart pill and connection notice. The tabs'
  keys are in the View menu and each tab's tooltip, not drawn in the bar.
- The tabs replace the Overview | Arrange toggle in the grid header. The
  header keeps the workspace count and the key hints.
- **Keys**: ⌥⌘1 Workspaces, ⌥⌘2 Overview, ⌥⌘3 Arrange, in the View menu and
  the palette. ⇧⌘R still toggles between Workspaces and the grid view used
  last. Esc from Overview or Arrange still returns to Workspaces; inside a
  focused pane Esc still belongs to the terminal.
- The selected tab is derived, not stored: Workspaces while the grid is
  closed, otherwise the mode drawn (a live drag still forces Arrange).
- Each view keeps its place. A pane focused in Overview stays focused
  while Workspaces or Arrange is shown, after the grid closes (any route:
  a tab, ⌥⌘1, ⇧⌘R, Esc from the lanes) and through a drag; choosing
  Overview returns to it. Only ⌘[ or "‹ Overview" returns to the lanes,
  and a pane that closed meanwhile lands on the lanes. While the
  remembered pane is not on screen it raises Needs-you cards like any
  other pane, and Esc goes to the grid, not to its terminal. Choosing the
  tab already shown does nothing.
- During a drag the tabs are drawn but inert.
- The rail's All Workspaces button (the 2×2 grid glyph in the workspace
  list's header) is removed: the tabs are the way in.

### Lanes

Three equal columns, each scrolling on its own. Every pane appears in
exactly one lane, decided in this order:

1. **Needs you**: the pane has a card in the attention stack. The lane IS the
   stack: same cards, same raising, coalescing, lifetime and withdrawal rules,
   so the dock and the lane can never disagree. Grouped by workspace: the
   group holding the oldest card comes first, and inside a group the oldest
   card comes first, so the top card is still the oldest of all.
2. **Working**: the pane's status is `working`. Ordered by rail order
   (workspaces, then board, then herds), then by tab and pane order inside a
   workspace. A small workspace label sits above the first card of each
   workspace, so a workspace's agents stay together.
3. **At rest**: anything else, however long it has been quiet. Cards draw
   at reduced opacity.

At rest is sectioned by the time since each pane's last status change, most
recent first:

- **Last hour**: under 60 minutes.
- **Earlier today**: the same calendar day in local time, older than an hour.
- **Yesterday**: the previous calendar day.
- **This week**: within the last 7 days.
- **Older**: anything before that.
- **Unknown**: a pane with no known last change (Status history, below).
  Always last, after Older. Its panes follow rail order (workspaces, then
  board, then herds, then tab and pane order) instead of most recent first.

An empty section is not drawn. Each section starts with a small label in the
lane-title style (10.5pt semibold, tracked, `textLabel`, uppercase) followed
by a hairline rule to the lane's edge. Inside a section the cards sit in the
same tinted workspace groups as the other lanes: the group with the most
recent change comes first, and inside a group the most recent change comes
first. A workspace with panes in two sections has a group in each.

Older and Unknown each fold only when they hold more than 8 panes: the label
becomes a disclosure (chevron, label, count) that starts folded, and each
one's open or folded state is kept in `AllWorkspacesModeStore` while the view
is closed.
The lane's count includes a folded section's panes; the keys skip them.

A blocked or done pane whose card was cleared (⇧⌘U, or a "finished" card
that timed out) is not in Needs you; it falls to At rest.

Each lane's header shows its status dot, its name and its count. An empty
Needs you lane reads "Nothing needs you".

### A card

Every card sits in its workspace's group, whose label names the workspace
(a herd's reads `auth sweep · herd 2/4`), so a card says its task once
(board `13 · Overview · labels, groups, quieter cards`).

Top line: status dot, the card's title (Titles, below) on one line, and at
the right the state and its age in the terminal face, `working 18m`, in the
status hue. A pane whose last change is unknown shows the status word alone,
`idle`, with no age.

Second line, only when there is one: a small dim line (12pt, `textDim`).
With One title on, it is the pane's own `displayTitle` when the tab holds
two or more panes and the title differs from the tab's, ignoring case. With
it off, it is the tab's title when that differs from the pane's.

Bottom line: the pane's repo and branch in the terminal face as Settings >
Overview > Bottom line words them, and at the right a timeline of the last
60 minutes: working, blocked and done as solid segments in their hues, idle
as a thin line, time with no record as the track alone. **Branch** (the
default) drops the repo when it is named like the workspace, ignoring case,
and shows `repo @ branch` otherwise; **Repo and branch** always shows both;
**Hidden** shows no text and leaves the timeline. A folder with no branch
shows its name in either text setting.

A blocked card carries a 1.5pt outline in the blocked hue.

**Identity grouping** (board `05c · Overview · identity groups`). Overview
wears Arrange's neutral wash so the two read as one place:

- In every lane, each workspace's cards sit in a group on the neutral
  workspace wash, the same ground and strength as its Arrange island
  (radius 10, 10pt padding, 10pt between cards). The group label is the
  workspace's symbol (14pt, primary text colour) and its name in the label
  grey; no rule. Cards keep the `chrome` ground.
- Status keeps its own colours: dots, ages, the blocked outline and the
  timeline stay in status hues, and nothing a workspace wears is a hue.
- A herd's group wears the same wash and its ram, as in Arrange.

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
- There is no Jump Back: Overview's tab and the focused view's back button
  are the ways back, and ⇧⌘J is unbound.
- **⇧⌘U, Clear Notifications** moves here from ⇧⌘J.
- **Arrows** move a selection ring between cards (up and down inside a lane,
  left and right across lanes, keeping the nearest row). The first open
  selects the top card of the first non-empty lane. **Esc** closes the view.

The header's right side shows the keys: `⌘J oldest · esc`.

**The main window's focused pane.** herdr's focused pane raises no card while
the main window's canvas shows it: the user is looking at it. While Overview
or Arrange covers the canvas it is not being watched, so it raises cards like
any other pane, and opening the grid raises the card it held back if it is
blocked or done and has none. The pane shown in Overview's focused view
raises none whatever the grid does.

### Focused pane

Boards `11 · Overview · Focused pane` and `14 · Focused pane · Next in the
queue`. Opening a card from Overview shows that one pane, live, inside the
All Workspaces view, with back to Overview and on to the next card as the
only ways to navigate. A jump from Overview no longer lands
in the main window, which had no visible way back.

**Opening.** A card click or Return, and ⌘J while Overview is shown (the
oldest card), open the pane here. A Needs-you card is dismissed on opening.
⌘J and dock clicks from the main window jump in the main window as before.

**What it draws.**

- A header the grid header's height:
  - left: a "‹ Overview ⌘[" button, then the workspace's symbol, `workspace ›
    title` (workspace in the dim text colour, the card's title and its
    second line dim after it), the status dot and the state with its age
    (`blocked 12m`) in the status hue;
  - right: a Next chip naming the oldest other Needs-you card: `NEXT`, its
    status dot, its workspace in the dim text colour, its card's title, its state
    and age in the status hue, `+N` when more than that one wait, a rule
    and `⌘]`. Clicking it opens that card here. With no other card it
    reads "Queue clear", dim, and does nothing.
- Below it, the pane exactly as the main window's canvas draws it,
  filling the space: its terminal, title and status chip, and its
  top-right legend controls (mouse badge, chat button, rt button). Typing
  goes to it. The rt modal and the chat popover open from it as they do
  in the main window. The zoom badge is not shown: there is no zoom here
  to leave.
- No tab strip, rail or dock, so nothing reads as navigation but the back
  button.

**Keys.**

- ⌘[ (Back to Overview) or "‹ Overview" returns to Overview with this
  pane's card selected and scrolled into view.
- ⌘] (Open Next Card) or the Next chip swaps in the card the chip names,
  staying in the focused view; ⌘J does the same. Both menu items are
  enabled only while a pane is focused here; the palette never opens over
  the grid, so it does not list them.
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

**Islands.** Each workspace is a region filled with one neutral wash, the
label grey at low strength (about 10 percent over the canvas), the same for
every workspace; corner radius 14, with no outline. The workspace you came
from adds a 1.5pt outline in the label grey. Islands sit 28pt apart; inside one, tabs sit 8pt apart, so the gap
between workspaces is always clearly wider than the gap within one.

**Island header.** The workspace's symbol (14pt, primary text colour), the workspace name at
16pt semibold (emoji included), its status dot, and the tab count at the
right.

**Thumbnails.** No outline. A thumbnail is a `pane`-filled block; its handle
is the tab title and status dot on no fill, except the tab you came from,
whose handle is underlined as the tab strip underlines a selected tab. Mini panes are
`tabRest` blocks with the status word and the title wrapped to three lines. A
blocked mini pane keeps a 1.5pt outline in the blocked hue, the only outline
inside an island.

**Order.** Islands pack left to right in rail order (workspaces, then
board's, then herds), wrapping to a new row when the next island would not
fit. Board's islands share the board's logo and herds the ram.

**Fit to window.** One thumbnail width is chosen for the whole view: the
largest, from 120pt up to 260pt, at which every island fits the window
without scrolling (height follows at a fixed, short ratio of 0.62). Below 120pt the view
scrolls instead of shrinking further. The size is decided when the view
opens and when the window resizes, never during a drag, so a drop target
never moves under the pointer.

Every workspace is drawn as an island, however long its panes have been
quiet.

## Data

### Status history

A new FlockCore type records, per pane, every status transition with its
time, as `paneAgentStatusChanged` and snapshots arrive, and drops entries
older than 60 minutes (keeping the transition that was in force at the
window's start). The timelines live in memory, so after a launch they start
empty and fill in.

Each pane's last change (its status and when it entered it) is kept across
launches by `PaneLastChangeArchive`, in UserDefaults under
`flock.paneLastChange`, saved whenever a pane's last change moves and pruned
to the panes herdr still reports. When the first snapshot after launch shows
a pane whose recorded status is still its status, the pane is recorded as
having entered it at the recorded time. So a pane quiet since yesterday
still rests under Yesterday after a relaunch.

Any other pane in that first snapshot (a fresh install, a pane flock never
saw change, or one whose status changed while flock was closed) began its
current status at an unknown time. Its timeline starts at launch, with the
track before it empty, but it has no last change: its age and last change
are nil, nothing is persisted for it, and it rests under Unknown. Its first
observed status change records a real time as for any pane. A pane that
appears after that first snapshot began just now and is dated then.

It answers, for a pane: the current status's age, the timeline segments for
the last 60 minutes, and the time of the last change, each nil when the last
change is unknown. It takes the clock as a parameter so tests control time.

A shell with no agent never changes status, so it rests in an older section
even while a command runs in it. Using `PaneForegroundJob` to tell busy
shells apart is a follow-up, not part of this work.

### Titles

Board `15 · Settings · Overview cards`. Settings has a **Titles** section
with one toggle, "One title for a one-pane tab", on by default and persisted
like the other stores (`OneTitleStore`). It is display only: it never
writes to herdr.

While it is on, a pane in a tab holding exactly one pane (counted from the
model, so a zoomed tab of two still has two) has no title of its own
anywhere flock names it. The tab's title (`TabTitle.resolve`: its name, or
the pane's title when the tab has none) is the one title:

- the pane's title row, in the main canvas and the focused view, draws no
  title text; the status chip, grip and legend controls stay where they
  were, and the row keeps its clicks;
- Arrange's mini panes in such a tab show the status word alone;
- Overview cards, the focused view's header and the Next chip lead with
  the tab's title (A card, above);
- dock cards name the tab, with a breadcrumb of the workspace alone;
- the grid's pane preview card and drag proxies name the tab.

Renames follow: Rename Pane (both context menus, the palette and the card's
menu), a double-click on the title row and the rename key all open the
editor on the tab, with the tab's current name. The main window's tab strip
draws that editor; the focused view's title row and an Overview card draw
it themselves. Clear Pane Name is hidden for such a pane while the setting
is on.

A tab herdr only numbered says nothing, so a number never leads a card and
never fills its second line: a card in an unnamed tab of several panes
leads with the pane's title.

The rule is one FlockCore type, `PaneNaming`, that every surface reads.

### Workspace symbol

Colour means status only, so a workspace is told apart by a symbol, never a
hue. The set is `WorkspaceSymbols`: about 180 SF Symbols in eight sections
(Engineering and Work first, then Tools, Nature, Things, Travel and sport,
Shapes, Animals) with no check, exclamation, clock, bell, cross or plain
disc, the shapes status already uses. Twenty engineering-leaning ones that
look least alike are assigned first. The symbol draws at
14pt in the primary text colour; every workspace's wash is the same
neutral. Flock assigns the least used symbol to a workspace the first time
it sees it (the earliest in assignment order breaking ties, so neighbours
do not repeat), keyed by workspace id so a rename keeps the symbol, and stores the
assignment in UserDefaults. Where the mark draws a symbol, on an Arrange
island's header and an Overview group's header, it is a button: it lifts on
hover over a small rounded ground, shows a link pointer and the tooltip
"Change symbol", and opens a popover pointing at the mark: Automatic pinned
above a scrolling grid of the set's icons in labelled groups, the current
symbol selected and each cell's name as its tooltip. A pick stores an
override the same way and closes the popover. Board's logo and a herd's ram
have nothing to pick and are not buttons.

The right-click menu anywhere on an island in Arrange, or anywhere on a group
in Overview (its wash, header and padding), is the rail's menu for that
workspace (Rename, Close), with Change Symbol... between them when the mark
is a symbol; it opens the same popover on the header's mark. A Board
workspace or a herd has no menu, as in the rail. Rename opens an inline
editor in the group's or island's header, since the rail is not on screen
there; a workspace with a group in several lanes shows it in the first lane
it appears in. A pane card's menu is Rename Pane and Close Pane only.

Assignments for workspaces herdr no longer reports are dropped whenever the
view opens.

The symbol appears in Arrange, in Overview and in the rail, where a
workspace row reads status dot, symbol, name. The rail's symbol is a button
like the others, and the rail's workspace menu carries Change Symbol... too.
Every view that draws symbols assigns them to workspaces it meets first. The
tab strip stays as it is.

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

- A workspace symbol in the tab strip.
- A separate or torn-off mission-control window.
- Recent output lines on cards (costs a `pane.read` per pane per refresh).
- Keeping the 60-minute timelines across launches (only each pane's last
  change is kept).
- Telling busy agentless shells apart from quiet ones.

## Testing

FlockCore unit tests:

- the status history: recording, trimming at 60 minutes with the in-force
  entry kept, age and segment answers under an injected clock, and a pane
  first seen with no record having no last change until its status changes;
- the last-change archive: a matching status keeps its recorded date, a
  different one has an unknown last change, an unknown time is never saved,
  and a pane herdr no longer reports leaves the archive;
- lane assignment and its precedence, including a cleared blocked card and a
  pane quiet for weeks;
- At rest's sections under an injected clock and calendar: 59 against 61
  minutes, midnight, yesterday, 7 days, the calendar's time zone, Older and
  Unknown folding only past 8 panes each, and Unknown last in rail order;
- lane ordering: Needs you grouped by workspace with the oldest card on
  top, rail-ordered Working with label breaks, At rest's sections most
  recent first with workspace groups most recent first inside each, and the
  keyboard's columns walking the drawn order, a folded section skipped;
- the main window's focused pane: no card while the canvas shows it, a card
  while the grid covers it, the held-back card raised as the grid opens,
  and none for the pane in Overview's focused view;
- `HEAD` parsing for a branch, a detached head and a missing file;
- `PaneNaming`: a named and an unnamed one-pane tab, a tab of two, a zoomed
  tab of two, the setting off, a pane moving between tabs, the rename
  target, Clear Pane Name hidden, and dock cards naming the tab;
- the bottom line's three settings and its store;
- the fit-to-window size: largest width that fits, the 120pt floor, the
  260pt cap, and no change while a drag is live;
- island packing in rail order;
- identity assignment: stable across a rename, overrides kept, stale ids
  dropped, and no palette hue near a status hue in any builtin theme;
- the focused pane: opening from a card or ⌘J, ⌘J and ⌘] swapping to the
  next oldest card and doing nothing when none remain, back selecting the card, a
  closed pane returning to Overview, and no herdr focus call on any of them.

FlockChromeRender tests render mission control and Arrange with fixture data in a dark
and a light theme, writing PNGs under `FLOCK_GRID_RENDER_DIR`, and samples a
blocked card's outline and a lane header's dot. They also render the focused
pane (its header and its pane's legend controls) and Overview's identity
groups in both themes. The UI is looked at in both themes before it is
called done.
