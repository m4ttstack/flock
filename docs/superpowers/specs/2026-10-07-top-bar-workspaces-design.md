# Top-bar workspaces

## Goal

Some workspaces are kept open only to glance at: an account dashboard, a
board, a log tail. They cost a rail row and a workspace switch every time.
A top-bar workspace leaves the rail and every other workspace list, shows as
its icon in the title bar beside Workspaces | Overview | Arrange, and opens
live in an overlay on click. The overlay is interactive: keys reach its panes
as they would in the grid.

Success: a pinned dashboard workspace moved to the top bar is gone from the
rail, Overview, Needs you, Arrange, the switcher, Move-to and toasts; its
icon carries its status dot; one click shows it live from any view; Esc puts
it away; it survives a herdr restart.

## Model

A top-bar workspace is a pin with a placement.

- `PinnedWorkspace` gains `placement: PinPlacement` (`.rail`, `.topBar`).
  A stored pin without the field decodes as `.rail`; `storedVersion` stays 1.
- `PinnedWorkspaceStore` keeps one array. The rail draws the `.rail` pins in
  array order, the title bar the `.topBar` pins in array order.
- `setPlacement(_:to:at:)` moves a pin between placements, inserting it at
  an index counted among the destination placement's pins as drawn.
  `move(_:toInsertIndex:)` takes its index the same way, within the pin's own
  placement.
- "Move to Top Bar" on an unpinned workspace pins it (name and folder as Pin
  does today) with `.topBar` placement, appended last. If its name is taken
  by another pin, it is refused the same way Pin is.
- Icons stay in `WorkspaceIdentityStore` under the pin's identity key
  (`pin:<uuid>`), so a placement change keeps the icon.

## Hiding

`SessionModel.withoutFlockOwned` becomes `visible(hiding:)`, taking the
workspace ids linked to `.topBar` pins in addition to the flock-owned ones.
`SessionViewModel` applies it once where it applies the current filter, so
every view that reads `viewModel.model` drops top-bar workspaces with no
per-view change. `fullModel` stays unfiltered.

- Focus inside a hidden workspace reads as none, as it does for flock-owned
  ones, so the grid never selects a top-bar workspace.
- `RailSections` excludes `.topBar` pins from PINNED.
- `WorkspaceIdentityStore.keys` still includes top-bar pins, so their symbol
  is never handed to another workspace.
- Attention toasts are raised from the filtered model, so a top-bar
  workspace never raises one.

## Title bar

`TitleBar`'s trailing overlay gains a `TopBarWorkspaces` strip, leading the
restart pill and connection notice.

- One cell per `.topBar` pin: the pin's symbol only, cells drawn like
  `ViewTabButton` (flat, full bar height, ruled apart), excluded from the
  window drag region.
- Label: the Settings choice below decides whether a cell shows the symbol
  alone or the symbol and the pin's name, in `ChromeType.viewTab`.
- Status dot: the same dot and colors the rail row would draw for the
  workspace, computed from `fullModel`. None for an empty pin.
- An empty pin (nothing open) draws its symbol dimmed.
- Selected state (overlay open for it): `tabRest` fill and accent underline,
  as a selected view tab.
- Tooltip: the pin's name.
- `TitleBarFit.showsTitle` already accounts for `trailingWidth`; the strip
  sits inside that measured width, so a narrow window hides "flock" before
  cells collide with it.
- Context menu: Move to Sidebar, Rename, Change Icon…, Unpin. Rename and
  Change Icon… reuse the pin rename editor and `WorkspaceSymbolPicker`, both
  presented from the cell. Unpin removes the pin; an open workspace reappears
  in the rail unpinned.

## Setting: icon only or with name

A new Settings section, "Title bar workspaces", with a two-way picker:
Icon only (default) and Icon and name.

- `TopBarLabelStore` in FlockCore, the usual `@Observable` UserDefaults store
  (`flock.topBarLabel`), passed to `FlockSettingsView` and read by the strip.
- With names on, the strip is wider. If the strip with names would not fit
  between the view tabs and the trailing notices, every cell falls back to
  icon only (all or none, never a mix), so the bar never clips or overlaps.
  `TitleBarFit` gains that check next to `showsTitle`, and the hidden
  "flock" title still goes first.
- The tooltip shows the name in both modes.

## Reordering and moving by drag

`DropTarget` gains `.topBar(insertIndex:)`, valid for `DragSubject.pin`.

- Dragging a top-bar cell along the strip reorders top-bar pins.
- Dragging a PINNED rail row onto the strip moves it to the top bar at the
  drop index; dragging a cell onto PINNED moves it back to the rail at that
  index. Both go through `setPlacement`.
- Dragging a cell anywhere else cancels.
- The cell's drag starts through the existing `DragCoordinator`, so the
  title bar's window-drag handling does not take the gesture, and the strip
  reports its insertion frames in `DragSpace` like the rail does.
- A drop on the strip while the window is too narrow to draw it is not
  possible: no frames, no target.

## Overlay

`TopBarWorkspaceOverlay`, mounted on `MainWindow` over everything below the
title bar (rail included), so it opens from Workspaces, Overview and Arrange
alike.

- State: `TopBarOverlayStore` holds the open pin, or none. One open at a
  time; clicking another icon switches, clicking the open one closes.
- Content: the workspace's active tab, `PaneCanvas` over `fullModel`'s
  layout for it, attaching surfaces the way `RtModalPane` does. A compact
  tab strip shows above it only when the workspace has 2+ tabs; choosing a
  tab there focuses it in herdr.
- Frame: a card inset from the content area, with a header showing symbol,
  name, and ✕. Background dimmed behind it.
- Focus: on open, keyboard focus goes to the active tab's focused pane.
- Closing: Esc, ✕, a click on the dim, or the icon again. Surfaces return to
  parked as the rt modal's do. Opening it closes the rt modal, the command
  palette and the switcher; opening any of those closes it.
- Empty pin: clicking it creates the workspace in the pin's folder through
  the empty pin row's path, then opens the overlay when the link confirms.
  A failed create shows the error in the overlay card instead of a canvas.
- A linked workspace that closes while open closes the overlay and leaves the
  cell empty.

## Out of scope

Per-workspace overlay size, a shortcut per icon, top-bar entries in the
command palette.

## Testing

FlockCore unit tests:

- Decoding a stored pin without `placement` gives `.rail`.
- `setPlacement` and `move` indices within each placement.
- `visible(hiding:)` drops top-bar workspaces, their tabs, panes and layouts,
  and clears focus that sits in one.
- `RailSections` omits `.topBar` pins.
- Menu model entries for a top-bar cell and "Move to Top Bar" on a rail row.
- The drag planner for `.pin` onto `.topBar(insertIndex:)` and back onto
  `.pinnedRail`.
- `TopBarOverlayStore` open/switch/close and mutual exclusion with the rt
  modal.
- `TopBarLabelStore` default and persistence; `TitleBarFit` falling back to
  icons when the named strip does not fit.

`FlockChromeRender`, in a dark and a light theme, looked at before done:

- Title bar with three cells: one with a working dot, one empty (dimmed),
  one selected; once icon only, once with names, and once with names in a
  window narrow enough to force the icon fallback.
- The Settings window with the new section.
- The overlay open over Workspaces with a one-pane workspace, and over
  Overview with a two-tab workspace.
