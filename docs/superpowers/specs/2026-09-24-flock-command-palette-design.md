# Command palette

**Goal:** one key opens a searchable list of everything flock can do in one
step, so the commands used daily (rt above all) are two or three keystrokes
away and the rest can be found without knowing their shortcut.

**Status:** design approved 2026-09-24. flock only.

## Why

flock's commands are spread over the menu bar (File, View, Chat), a pane's
right-click menu, the pane legend's buttons and the rt popover. The rt
commands have no key at all, and the shortcuts that exist are only learnable
by reading menus. A palette puts them all behind one key and shows each
command's shortcut as it goes.

## What exists today

The palette reads these; it does not replace them.

| Family | Commands | Keys | Where it lives |
|---|---|---|---|
| pane | Split Right, Split Down, Close Pane | ⌘D, ⇧⌘D, ⇧⌘X | `FocusedPaneCommand.all` |
| pane | Focus, Move, Swap ×4 directions | ⌥⌘, ⌃⌘, ⌃⇧⌘ + arrow | `PaneDirectionCommand.all` |
| pane | Zoom, Rename | F2 for Rename | `PaneMenuAction`, `beginRenameFromShortcut` |
| mouse | Send right-clicks to the program / to flock | ⌥⌘M | `SessionViewModel.toggleFocusedPaneRightClicks` |
| rt | nav, glitter, run, runner | none | `RtPopoverModel.commands` |
| chat | Chat Panel, Broadcast, Peek, Quick Send, Open Viewer, Sign In, Sign Out | ⇧⌘C/B/P/S/V/I/O | `ChatMenuItem`, `ChatMenuModel.rows` |
| view | Rearrange Mode, All Workspaces, Open Oldest Notification, Clear Notifications | ⌘R, ⇧⌘R, ⌘J, ⌘K | inline in `FlockApp`'s View menu |
| tab, workspace | New Tab, New Workspace | ⌘T, ⇧⌘N | inline in `FlockApp`'s File menu |

## Behaviour

**Opening.** ⌘K opens the palette; it is a View menu item, "Command
Palette…", so the key shows in the menu bar. Clear Notifications moves from
⌘K to ⇧⌘K. Esc, a click on the scrim, or ⌘K again closes it. It opens while
the rt modal is up too; a pane command run from it closes the modal first.
While the rename editor is open, ⌘K is the editor's.

**Where it draws.** Over the tab area (tab strip and panes), under a scrim,
the same region the rt modal uses; the sidebar stays clear and undimmed.

**Empty search.** RECENT lists up to 3 commands, most recently run first,
then ALL COMMANDS lists the rest grouped by namespace in the order rt, pane,
chat, mouse, view, tab, workspace, each group in its source list's order. A
command in RECENT is not repeated in ALL COMMANDS. The first row is selected.

**Typing.** One fuzzy search over "namespace name" (`rt glitter`,
`pane Split Right`), in the manner of VS Code's command mode: there is no
prefix syntax, the namespace is simply part of what is matched, so `rt`
narrows to rt and `rt gl` finds glitter. Results are one list without
sections, ranked by match quality with a small boost for commands run
recently. The characters of the name that matched draw in the theme accent.

**Running.** ↑ and ↓, or ⌃P and ⌃N, move the selection; it does not wrap.
Return or a click runs the selected command and closes the palette. A
command acts on the canvas's focused pane, exactly as its menu item or
button does. Running records the command in recents.

**Availability.** A command that cannot run right now is not listed at all:
no Focus Pane Left with no pane to the left, no chat rows unless chat is
available and the focused pane runs Claude Code, no mouse row unless the
focused pane's program has the mouse, no rt rows unless rt is on the
startup PATH. Each rule is the one the command's own menu item or button
already uses.

**Recents.** Kept across launches in UserDefaults
(`flock.paletteRecents`): an ordered list of command ids, most recent first,
without duplicates, capped at 20 stored; 3 are shown. An id that no longer
names a command is skipped when shown.

## Commands in the first version

Every one runs on Return with no second choice.

| Namespace | Commands |
|---|---|
| rt | nav, glitter, run, runner (titled Start Runner or Show Runner) |
| pane | Split Right, Split Down, Close Pane, Zoom Pane, Rename Pane, Focus / Move / Swap Pane Left, Right, Up, Down |
| chat | Chat Panel, Broadcast to Panes…, Chat Peek, Quick Send…, Open Viewer, Sign In This Pane, Sign Out This Pane |
| mouse | one row, titled for what it will do: Send Right-Clicks to Program, or Give Right-Clicks to Flock |
| view | Rearrange Mode, All Workspaces, Open Oldest Notification, Clear Notifications |
| tab | New Tab |
| workspace | New Workspace |

Not in this version: Theme, Text Size, Option as Alt, Scroll Speed and Move
Pane to…, which need a second choice (a later sub-list); Swap with Focused,
which needs a target; Undo and Redo.

## Look

Canvas: `docs/design/palette/palette-dark.png` and `palette-light.png`
(from the Pen canvas `flock rt.pen`).

- **Box:** 520 wide, 44 below the top of the tab area, horizontally centred
  in it. Fill `theme.chrome`, 1pt `theme.rule` stroke, r10, clipped. Shadow
  black at 35%, offset y 12, blur 32.
- **Scrim** over the tab area, the rt modal's.
- **Search row:** 44 tall, pad 0/14, gap 10: a 15pt magnifier in
  `theme.textLabel`, then the field at 14 in `theme.textStrong`, placeholder
  "Search commands" in `theme.textLabel`. A 1pt `theme.rule` line below.
- **List:** pad 6, rows 1 apart. Section labels (RECENT, ALL COMMANDS) at
  10/600, letter spacing 0.8, `theme.textLabel`, pad 8/8/4/8.
- **Row:** 32 tall, pad 0/8, gap 10, r6. Selected: `theme.selection` fill,
  name at weight 500. In order: the badge, the name at 13 in
  `theme.textStrong`, a spacer, the shortcut at 12 in `theme.textLabel` when
  there is one.
- **Badge:** 44x18, r4, one neutral style for every namespace: fill
  `palette.surface0` in a dark theme and `palette.surface1` in a light one
  (surface0 is too close to a light chrome to read), text at 10.5/600 in
  `theme.textLabel`, centred. No per-namespace colour.
- **Match highlight:** matched characters of the name in `theme.accent`.
- **Footer:** 30 tall, pad 0/14, gap 14, a 1pt `theme.rule` line above:
  "↑↓ move", "↵ run", "esc close" at 11 in `theme.textLabel`.
- **Hover:** a row under the pointer takes the legend's hover wash; the
  selection follows the pointer only on click.

## Architecture

**FlockCore** (pure, where the tests live):

- `PaletteNamespace`: rt, pane, chat, mouse, view, tab, workspace, in the
  order ALL COMMANDS groups them.
- `PaletteCommand`: a stable `id` (the recents key, e.g. `pane.splitRight`),
  a namespace, a name, and a shortcut label. No action.
- `PaletteMatcher`: fuzzy subsequence match of a query against
  "namespace name", case-insensitive. Returns nil for no match, else a score
  (consecutive runs and word starts score higher) and the indices of the
  name's matched characters.
- `PaletteRanking`: from the available commands, the query and the recents,
  the rows to show: for an empty query the RECENT and ALL COMMANDS sections,
  for a typed one the ranked list with the recency boost.
- `PaletteRecentsStore`: `@Observable` over an injectable `UserDefaults`,
  as `RtModalSizeStore` is.

**App:**

- `PaletteCommandSource`: builds `(PaletteCommand, action)` pairs for this
  moment from the existing lists (`FocusedPaneCommand.all`,
  `PaneDirectionCommand.all`, `ChatMenuModel.rows`,
  `RtPopoverModel.commands`, the right-click toggle), using the same
  availability each menu item or button uses, and a new `ViewCommand` list.
- `ViewCommand`: the View menu's one-shot items and New Tab / New
  Workspace, each with its title and shortcut. The menu bar and the palette
  both read it, so a shortcut lives in one place; ⇧⌘K is set there.
- `CommandPaletteView`: the overlay on the tab area, like `RtModalView`,
  with a key monitor like `RtModalKeyMonitor` for ↑ ↓ ⌃P ⌃N Return Esc.
  Which key does what is a pure `PaletteKey` decision in FlockCore.
- While open, the palette counts as an open editor (the flag the rename
  editor sets), so a pane's terminal does not take the keyboard back; on
  close, focus returns to the pane.

## Testing

- **FlockCore:** the matcher (subsequence, case, score order, matched
  indices); ranking (recents first and capped at 3, no repeats, grouping
  order, recency boost only on typed queries, unavailable commands never
  present); the recents store (persists, deduplicates, caps at 20, skips
  unknown ids); `PaletteKey`.
- **Render, dark and light:** the palette over the window with an empty
  search and with a typed query showing the highlight; availability (no
  chat rows on a shell pane, no mouse row without mouse capture); a real
  click on a row runs its command and closes the palette; ⌘K opens it and
  Clear Notifications answers ⇧⌘K.
- PNGs of each state, looked at before a task is called done; the full core
  and render suites and `Scripts/checks.sh` before each commit.
