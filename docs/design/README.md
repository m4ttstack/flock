# Paddock design references

Task 14 design-canvas gate deliverables. The live canvas (editable, exports PNG/PDF) is the "Paddock Design" artifact: https://claude.ai/code/artifact/e891da81-51e1-46b7-875e-9bdb20bda905

- `main-dark.png` / `main-light.png`: window anatomy (workspace rail, tab strip, pane canvas) rendered in two THEMES, Tokyo Night and Tokyo Night Day (paddock has named themes mirroring herdr's 17 built-ins, no light/dark modes). Terminal cells keep the terminal's own ground (#191A22) in every theme.
- `pane-states.png`: live/focused, detached status card, zoomed tab, blocked-agent attention, rename-in-place, hover close, agent status vocabulary.
- `drag-states.png`: ghost + origin, 20% edge bands + interior, split preview, insertion bars, new-tab/new-workspace zones, spring-loading, rejection toast, spring parameters.
- `all-workspaces.png`: the zoomed-out grid as a live drop surface.
- `interactions.png`: attention toasts (click jumps to the source pane), copy-on-selection parity, right-click routing (herdr 0.9 `pane.input.set`), Option+click gesture (v1.5 input channel).

Agent status colors mirror herdr's header semantics (`src/client/shell.rs` `status_color`), drawn from the active theme: working = yellow, blocked = red, done = teal, idle = green (hollow ring), unknown = overlay (centered dot). The references show Tokyo Night (`#E0AF68`/`#F7768E`/`#7DCFFF`/`#9ECE6A`/`#565F89`) and Tokyo Night Day. The zoom badge is theme mauve so it never reads as a status.

`src/` holds the artboard sources (plain HTML; each renders standalone and as a canvas artboard). Terminal text and pane titles are illustrative; chrome, spacing, states, and colors are the proposal implementation must match.
