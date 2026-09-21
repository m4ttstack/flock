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

## The mark is vector, not an image

No squircle ground: just the ram and its trail over the pane.

**It is drawn from the icon's own path, in the app.** `HerdrRam.path()` in
`Scripts/HerdrRamPath.swift` is a real `CGPath`, and `Scripts/make-icon.swift`
already paints the trail as FOUR SEPARATE FILLS of it: three echoes, each
offset along one axis with its own colour and alpha, then the leader on top.
The loader draws the same four copies as SwiftUI paths.

An earlier version of this design called for exporting a transparent PNG. That
was a mistake: flattening to pixels is what would have made the trail
unanimatable, and it would have added an asset to keep in sync with the icon.
Vector costs nothing extra and removes both problems.

The echoes step back at the SAME scale as the leader. Scaling them down would
read as three animals standing at different distances rather than one animal
moving.

## Minimum display: 1500ms

Ruled by Matt on 2026-09-20 at 2000ms, lowered to 1500ms the same evening after
seeing it run. Once the loader is shown it stays for at least that long, even
when the first frame arrives sooner.

This is a deliberate trade and it is worth stating plainly: it makes flock
slower on purpose. A pane that could have shown content in 80ms will hold the
loader for 1.5s, and a workspace opening four panes holds all four
(concurrently, so 1.5s total rather than 6s). The gain is that the moment is
actually seen instead of flickering past.

**The trail's loop is sized to this number, not the other way round.** One
gather-hold-release is `PaneLoaderChoreography.loopDuration`, and it is set to
land inside the floor so the guaranteed window always contains a whole gesture.
Lowering the floor again means shortening the loop with it, or the release gets
cut off mid-drift on every fast attach.

## Size: 128pt

Ruled by Matt on 2026-09-20, the largest of the three the canvas compares.

## The trail is the animation

The echoes slide forward into the leader and re-separate, on a loop. Catching
up is literally what attaching is, which is why this beats a spinner: the motion
means something.

Alongside it:

- **The mark fades in**, rather than appearing hard.
- **The ellipsis cycles** through one, two and three dots.
- **A fade out** when the first frame arrives, so the handover to real terminal
  content is a transition rather than a cut.

No breathing or pulsing scale. An earlier draft proposed one as a substitute
for real motion, and with the trail moving it would only compete.

The display floor is what makes any of this worth building. At the 80ms a fast
attach actually takes, every one of these would be invisible.
