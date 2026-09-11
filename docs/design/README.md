# Paddock design references

Task 14 design-canvas gate deliverables. The live canvas (editable, exports PNG/PDF) is the "Paddock Design" artifact: https://claude.ai/code/artifact/e891da81-51e1-46b7-875e-9bdb20bda905

- `main-dark.png` / `main-light.png`: window anatomy (workspace rail, tab strip, pane canvas), focused pane, connection badge, protocol readout. Terminal cells keep the dark ground (#191A22) in both passes; only the chrome changes.
- `pane-states.png`: live/focused, detached status card, zoomed tab, blocked-agent attention, rename-in-place, hover close, agent status vocabulary.
- `drag-states.png`: ghost + origin, 20% edge bands + interior, split preview, insertion bars, new-tab/new-workspace zones, spring-loading, rejection toast, spring parameters.
- `all-workspaces.png`: the zoomed-out grid as a live drop surface.

`src/` holds the artboard sources (plain HTML; each renders standalone and as a canvas artboard). Terminal text and pane titles are illustrative; chrome, spacing, states, and colors are the proposal implementation must match.
