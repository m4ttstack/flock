# The pane loader

Design canvas: `~/Documents/flock loader.pen`.

## What it replaces

`PaneCellView` draws the live terminal at `opacity(hasFirstFrame ? 1 : 0)` and
shows a card underneath until herdr sends the pane's first frame. That card was
the same one the All Workspaces grid uses: a terminal glyph, the cwd tail, the
pane's last output line in a bordered pill, and the hint "click to focus in
herdr". Four pieces of chrome at the same weight, none of which say what is
happening.

It was also unreadable in practice. Attach is usually fast enough that the card
appears and vanishes before anyone can focus on it, which reads as a flicker
rather than as a state.

## What it becomes

The app mark, with its colour-separated motion trail, over the words
**"gathering the flock..."**. Nothing else. The cwd and the last output line are
gone, and so is the herdr hint, which predated flock being able to drive panes
at all.

The mark carries the meaning the old card was trying to assemble out of
fragments: this is flock, it is working, wait a moment.

## The mark has no background

The app icon's squircle ground is `#1A1B26`, exactly `panelBg`, so the tile
edge already disappeared against a pane. Rather than rely on that coincidence,
the loader uses a transparent render of the ram and its trail alone.

**It comes from the same geometry as the icon.** `Scripts/make-icon.swift`
draws the squircle, clips to it, then paints three echoes and the leader.
The mark render is that same code with the ground and its clip dropped, so the
two can never drift into being different drawings of the same animal. A script
under `Scripts/` should emit both from one source; a hand-traced copy would
diverge the first time the icon changed.

## Minimum display: 2000ms

Ruled by Matt on 2026-09-20. Once the loader is shown it stays for at least two
seconds, even when the first frame arrives sooner.

This is a deliberate trade and it is worth stating plainly: it makes flock
slower on purpose. A pane that could have shown content in 80ms will hold the
loader for 2s, and a workspace opening four panes holds all four (concurrently,
so 2s total rather than 8s). The gain is that the moment is actually seen
instead of flickering past.

It is one constant. If two seconds wears thin in daily use, lower it; the
shape of the feature does not change.

## Size: 128pt

Ruled by Matt on 2026-09-20, the largest of the three the canvas compares.

## It animates, within what the art allows

**The echoes cannot move independently.** They are baked into a single flat
image, so the earlier idea of having them catch up to the leader and
re-separate is not buildable without new layered artwork. Anything claiming to
animate the trail itself would be animating a picture of a trail.

What does move:

- **The mark fades in**, rather than appearing hard.
- **A slow breathing scale** on the mark for the duration. Slow enough to read
  as alive rather than as a spinner, since nothing here is measuring progress.
- **The ellipsis cycles** through one, two and three dots.
- **A fade out** when the first frame arrives, so the handover to real terminal
  content is a transition rather than a cut.

The 2000ms minimum is what makes any of this worth building. At the 80ms a fast
attach actually takes, every one of these would be invisible.
