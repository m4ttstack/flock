# Pinned workspaces

**Goal:** a workspace can be pinned, making it a permanent place. A pinned
workspace stays in the rail with its name, symbol and order when every tab
and pane in it has closed, and clicking it brings it back as a fresh shell in
its home folder.

**Status:** design approved 2026-10-06. flock only.

## Why

Some workspaces are places work always returns to: a repo, an app inside a
monorepo, a notes folder. Today a workspace lives exactly as long as herdr's
does. Closing its last tab closes it (flock asks first), a shell exiting in the
last pane closes it with no asking at all, and a workspace opened again later
under the same name is a new workspace: a new id, a new symbol, a new place
in the order. Nothing remembers the place.

## What exists today

- herdr cannot hold a workspace with no tabs: closing the last tab closes the
  workspace. flock prompts first (`CloseConsequence`, reached through
  `SessionViewModel.closeTab`), but a pane that exits on its own, an agent
  finishing or `exit` in a shell, closes it without passing through flock.
- herdr workspace ids survive herdr restarts; a closed workspace's id is
  never reused.
- `workspace.create` takes `cwd` and `focus`. A rename follows as
  `commitRename(_:for: .workspace(_))`.
- The rail lists herdr's workspaces in herdr's order under WORKSPACES, then
  Board's and herds' sections. Reordering a row moves herdr's order.
- `WorkspaceIdentityStore` keys each workspace's symbol by herdr workspace id
  and drops keys for workspaces herdr no longer reports.

## Design

### The record

`PinnedWorkspaceStore` (FlockCore, `@Observable`, persisted to UserDefaults
under `flock.pinnedWorkspaces` as versioned JSON) holds the pins in rail
order. Each pin has:

- `id`: flock's own, stable for the pin's life.
- `name`: unique among pins, compared ignoring case and surrounding spaces.
- `folder`: the home folder a reopen starts in.
- `workspace`: the herdr workspace id it is linked to, nil when empty.

Unreadable stored data, or data from a newer version, loads as no pins, never
a crash, and stays stored until the person changes the pins.

### Pinning and unpinning

- **Pin** (workspace menu > Pin, or dragging a WORKSPACES row into PINNED at
  the drop position) records the current name and herdr id. The home folder
  is the folder of the workspace's first pane at that moment, as it is, never
  widened to its repo: one monorepo holds many places. Workspace menu >
  Change Folder... picks another with a folder panel.
- **Unpin** (menu, or dragging a live pinned row down to WORKSPACES) removes
  the pin and leaves the herdr workspace as an ordinary one.
- **Remove** (an empty pin's menu) deletes the pin.
- Board's workspaces and herds cannot be pinned: they sit in sections of their
  own and have no menu.

### Linking

On every model update, in this order:

1. A pin whose `workspace` herdr still reports stays linked; its `name`
   follows a rename made anywhere.
2. A pin whose `workspace` herdr no longer reports is unlinked and becomes
   empty.
3. An empty pin adopts the first herdr workspace, in herdr's order, that no
   pin is linked to and whose name matches the pin's (ignoring case and
   surrounding spaces).

A workspace linked to a pin is pinned; any other workspace sharing its name
stays ordinary. Links are restored across flock and herdr restarts by the
stored id, and by rule 3 when the id is gone.

### Reopening

Clicking an empty pin (in the rail or the workspace switcher) calls
`workspace.create` with the pin's folder as `cwd` and `focus: true`, renames
the new workspace to the pin's name, and links the pin to the id the create
returns, never by name. One reopen per pin is in flight at a time; further
clicks are ignored until it links or fails. When the folder no longer exists,
the reopen starts in the home folder and a notice offers Change Folder....
When the create fails, the pin stays empty and the failure takes flock's usual
notice.

### Closing

- The menu on a pinned workspace offers no Close. It is Rename, Change
  Symbol..., Change Folder..., Unpin. An empty pin's is Rename, Change
  Symbol..., Change Folder..., Remove.
- Closing the last tab of a pinned workspace skips the prompt that it would
  close the workspace: the workspace closes in herdr and the pin stays,
  empty.

### Names

A rename of a pinned workspace (rail, Overview group, Arrange island) renames
the pin. A rename to another pin's name is refused with a notice. An empty
pin renames in place, with no herdr call.

### Symbols

A pin's symbol is stored under the key `pin:<id>` in `WorkspaceIdentityStore`.
Pinning moves the workspace's assignment and override from its herdr id key to
the pin's key; unpinning moves them back to the herdr id now linked.
`keepOnly` keeps every pin key. Everything that draws a pinned workspace's
mark resolves it through the pin.

## The rail

- A PINNED heading, styled like WORKSPACES, above the WORKSPACES section.
  PINNED is absent while there are no pins.
- A live pinned workspace's row is a normal row (status dot, symbol, name,
  pane count) and appears under PINNED only.
- An empty pin's row: a blank where the status dot sits, the symbol and name in
  `textLabel` a step dimmer (`ChromeMetrics.WorkspaceRow.emptyPinOpacity`),
  no count. The workspace switcher draws an empty pin's row the same way. Clicking reopens and selects it; a double click
  renames.
- Dragging within PINNED reorders pins; that order is flock's. Reordering
  under WORKSPACES moves herdr's order, with target positions computed over
  herdr's full order so hidden pinned workspaces never displace a drop. An
  empty pin cannot be dragged out.

## Other views

- Anything that follows rail order (Arrange's islands and any shortcut that
  steps through workspaces) takes PINNED first, then WORKSPACES.
- The workspace switcher stays most recent first: a pinned workspace used
  recently sorts by recency, and empty and unused pins sit after the recents,
  ahead of workspaces never used.
- The workspace switcher lists empty pins; choosing one reopens it.
- Overview: no change but the menu. An empty pin has no panes, so no group.
- Arrange: an empty pin has no island.

## Testing

All hermetic, as the rest of the suite.

- `PinnedWorkspaceStore`: pin, unpin, remove, reorder, persistence round
  trip, unreadable data, unique names.
- Linking: each rule above, adoption ignoring case, first in herdr's order,
  names following renames, a reopen linking by returned id while a
  same-named workspace exists.
- Symbol keys moving on pin and unpin; `keepOnly` keeping pin keys.
- Rail ordering with pins, and WORKSPACES reorders computed past hidden pinned
  workspaces.
- The close prompt skipped for a pinned workspace's last tab.
- Reopen against the fake herdr client: create params, rename, link, a
  missing folder, a refused create, a second click while one is in flight.
- Render tests: the rail with a live and an empty pin, dark and light.
- No e2e run without Matt's OK.

## Out of scope

- Restoring a pin's tabs, splits or commands. A reopen is one shell.
- Pinning Board's workspaces or herds.
- Pins shared across machines.
