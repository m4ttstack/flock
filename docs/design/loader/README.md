# The pane attach badge

Design canvas: `~/Documents/flock loader.pen`.

## What it replaces

`PaneCellView` used to draw a card under the live terminal until herdr sent
the pane's first frame: a terminal glyph, the cwd tail, the pane's last output
line in a bordered pill, and the hint "click to focus in herdr". Four pieces of
chrome at the same weight, none of which said what was happening.

That became a full-pane loader: the app mark and its colour trail over
**"gathering the flock..."**, held for a full second so the animation could be
seen. It was built on 2026-09-20 and rejected in daily use the next morning,
for the reason it was designed: it made every pane announce itself.

> I think I just got all excited because I love the logo and wanted to make a
> pretty loader, but now that I'm using it, I'm finding it annoying to wait
> through every single time.

## What it is now

A small badge in the bottom-right corner of a pane that has not painted yet:
the ram with its trail, and the word **flocking**, with a cycling ellipsis.
Nothing else, and nothing in the middle of the pane.

**Most attaches never show it at all.** That is the point, and everything below
follows from it.

## The two timers

```
appearDelay    200ms   nothing is shown before this
minimumDisplay 400ms   once shown, the shortest it stays
```

`appearDelay` is why a fast attach is silent. A pane that paints in 80ms was
always about to be there; a badge for it is just something that flashed. The
timer is cancelled the moment the first frame arrives, so the common case
never reaches the badge at all.

`minimumDisplay` is why a badge that does appear cannot flicker. Once it is up
it holds, even if the frame lands immediately after. The floor is a minimum,
never a ceiling: a genuinely slow attach dismisses the instant its frame
arrives, with nothing added on top.

Worst case is `200 + 400 = 600ms` of badge, and only for a pane that was
already going to make you wait.

### What was removed

The floor used to be derived from the trail's loop length, so a dismissal
landed exactly where the echoes reached full spread. That mattered when the
loader owned the pane and a whole gesture was the thing being watched. A corner
badge is not watched, so the coupling bought nothing and taxed every future
change to the animation with a matching change to the floor. It is a plain
constant now.

## Two rules the pane has to get right

Both are in `PaneLoaderPolicy`, both are pure, and both exist because getting
them wrong shipped.

**`showsTerminalSurface(hasFirstFrame:badgeVisible:)`** needs both halves.
Revealing on `hasFirstFrame` alone puts live terminal content under a badge
that is still holding its floor. Revealing on `!badgeVisible` alone puts a
frame of live terminal on screen *before* the badge appears: a cold pane's
first render happens before the cell has decided anything, so "no badge yet" is
not "no badge coming", and libghostty has usually already painted by then. That
second one shipped and read as the terminal flashing, then being covered up.

**`showsLauncherOverlay(isPristineLauncherPane:badgeVisible:)`** holds the
harness buttons back until the badge is gone. A fresh pane is both things at
once, and when the loader was full-pane the two drew on top of each other. They
no longer collide on screen, but a pane that has not painted has no shell ready
to receive anything either, and the launcher's buttons work by sending the
harness name as input.

## The mark is vector, not an image

No squircle ground: just the ram and its trail.

**It is drawn from the icon's own path, in the app.** `HerdrRam.path()` in
`Sources/FlockCore/Marks/` is a real `CGPath`, and `Scripts/make-icon.swift`
paints the trail as FOUR SEPARATE FILLS of it: three echoes, each offset along
one axis with its own colour and alpha, then the leader on top. The badge draws
the same four copies as SwiftUI paths.

The echoes step back at the SAME scale as the leader. Scaling them down would
read as three animals standing at different distances rather than one animal
moving.

`HerdrRamTrail.path` fits and centres the WHOLE composition, leader plus the
farthest echo's offset, against the square it is given. Sizing or centring on
the leader alone puts the mark high and right of where it belongs and pushes
the farthest echo toward the frame.

## Size is fixed, not proportional

32pt at every pane size. The full-pane version scaled with the pane because it
was the pane's entire content; furniture that grows with its container stops
reading as furniture.

## The trail is the animation

The echoes slide forward into the leader and re-separate, on a loop. Catching
up is literally what attaching is, which is why this beats a spinner: the
motion means something.

Alongside it, the badge fades in, the ellipsis cycles through one, two and
three dots, and there is a fade out when the first frame arrives.

At a 400ms showing you catch part of a gesture rather than the whole loop. That
reads fine as motion, and a pane slow enough to show the badge for longer gets
the whole thing.

No breathing or pulsing scale. An earlier draft proposed one as a substitute
for real motion, and with the trail moving it would only compete.

## The colours are pinned

`HerdrRamTrail.Colors` are copied from `make-icon.swift` and never come from
the active theme. This is a logo: it has to read as the same ram under every
pane theme, the way the app icon does not repaint itself. Sourcing them from
`ThemePalette` was tried and reverted, because a theme with a green or orange
accent turned the ram into a different mark entirely. Only the caption's text
colour follows the theme.
