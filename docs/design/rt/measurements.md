# rt design measurements

Every number here was read out of `flock-rt.pen`. It is the implementation
target: a view is finished when it renders to these values. The reference PNGs
beside this file are the canvas exported at 2x, dark and light.

## Tokens map to flock's palette and chrome roles

The canvas uses flock's own names, so no colour is ever a literal hex in Swift
except rt's two brand colours, which are the same in every theme.

| Canvas token | flock | Tokyo Night | Tokyo Night Day |
| --- | --- | --- | --- |
| `$chrome` | `theme.chrome` | `#14151B` | `#E9EAEF` |
| `$pane` | `theme.pane` | `#191A22` | `#E0E1E3` |
| `$pane-border` | `theme.paneBorder` | `#50556A` | `#A6A6AA` |
| `$rule` | `theme.rule` | `#363948` | `#C3C4C8` |
| `$sel-role` | `theme.selection` | `#2B3A62` | `#B7CDED` |
| `$selection` | `palette.selectionBg` | `#2D3650` | `#B6CAE7` |
| `$surface-0` | `palette.surface0` | `#24283B` | `#C4C8DA` |
| `$text` | `palette.text` | `#C0CAF5` | `#3760BF` |
| `$text-strong` | `theme.textStrong` | `#E6E7EB` | `#191A1A` |
| `$text-dim` | `theme.textDim` | `#D0D2DC` | `#2D2D2E` |
| `$accent` | `theme.accent` | `#7AA2F7` | `#2E7DE9` |
| `$green` | `palette.green` | `#9ECE6A` | `#587539` |
| `$red` | `palette.red` | `#F7768E` | `#F52A65` |
| `$rt-plum` | `RtBrand.plum` | `#161224` | `#161224` |
| `$rt-pink` | `RtBrand.pink` | `#FF6B9D` | `#FF6B9D` |

Type is Inter throughout (`ChromeType`). `600` is semibold, `500` medium,
`700` bold.

## The legend

Order at the title row's trailing end: zoom badge, chat button, **rt button**,
status chip, all `ChromeMetrics.Pane.legendItemGap` (5) apart. There is no
separate runner button: a live runner is the rt button's second half.

**rt badge**, the mark inside every rt state: 16x12, fill `rt-plum`, r3, "rt"
centred at 8.5/700 in `rt-pink`.

**rt button at rest:** 27x17, fill `surface0`, r4, no stroke, the badge centred.
It matches signed-out chat's square exactly.

**rt button active:** height 18, width sized to content, fill `selectionBg`, r4,
pad 0/7, gap 5. In order:

| Child | Size | Colour | Present |
| --- | --- | --- | --- |
| Badge | 16x12 | as above | always |
| Count | h12, width from the text | `palette.text`, 10/600 | while any rt run item is running; the number of them |
| Divider | 1x10 | `palette.overlay0` | while the pane has a runner |
| Runner glyph | 11x11 | `rt-pink` | while the pane has a runner |

Active while the pane has running rt run items or a runner. **The count is rt
run items only**: the runner has its own half and is not counted again, so a
pane with a runner and nothing else reads as the badge, the divider and the
glyph. The glyph is lucide `activity` on the canvas; in SwiftUI it is the SF
Symbol `waveform.path.ecg`.

**Two targets in one pill.** Clicking the badge-and-count half opens the rt
menu; clicking the divider-and-glyph half shows the runner. Without a runner
the whole pill opens the menu.

**rt not installed:** no button.

## The rt popover

Clicking the rt button's badge half opens a popover below it, a SwiftUI
`.popover` like the chat button's, drawn in the chat popover's language.

300 wide, r10, fill `panelBg`, outer stroke `surface1` at 1pt.

**Header:** 41 tall, pad 12/14, gap 8, a 1pt `surface0` rule beneath. The rt
badge at 20x15, r3, "rt" at 10/700 in `rt-pink` on `rt-plum`; at the trailing
edge a folder chip: 18 tall, `surface0`, r4, pad 3/8, gap 5, a 10x10 folder
glyph in `overlay0` and the pane's folder (home as `~`) at 10/regular in
`subtext0`.

**Commands:** a band padded 6/8 holding four rows, each 31 tall, r5, pad 8,
gap 9: a 14x14 glyph, the label at 12/regular in `palette.text`, and rt's own
command as a hint at the trailing edge in JetBrains Mono 10 in `overlay0`. The
hovered row fills `selectionBg` and its glyph turns `accent`; other glyphs are
`overlay0`.

| Row | Glyph (canvas / SF Symbol) | Hint |
| --- | --- | --- |
| Browse files | `folder-open` / `folder` | `rt nav` |
| Git status | `git-branch` / `arrow.triangle.branch` | `rt glitter` |
| Run a script… | `play` / `play` | `rt run` |
| Start runner, or Show runner once one exists | `activity` / `waveform.path.ecg` | `rt runner` |

**RUNS:** shown only when the pane has rt run items. The label is 10/600 in
`overlay0`, tracking 0.5, pad 10/14/6/14. Item rows sit in a band padded
0/8/8/8, each 31 tall, r5, pad 8, gap 9: a 7x7 dot, the item's title at
12/regular in `palette.text`, and its state at 10/regular in `subtext0` at the
trailing edge. The dot is `green` while running, `red` once exited, `overlay0`
once finished. The state reads `running`, `finished · exit 0` (or `finished`
without a status), `exited 1`. A running row fills `activeRowBg`, the way a
peek row with unread does; the rest have no fill. Items list in the order they
were opened, and clicking one shows it in the modal.

## The modal

**Placement.** An overlay over the tab area only: the tab strip and the panes,
right of the sidebar. The sidebar, the title bar and any banner stay clear and
undimmed. The backdrop is black at 45%
in a dark theme and 30% in a light one. The box is 70%, 80% or 90% of the tab
area on each axis (the size control, below), centred in it.

**Box:** fill `theme.pane`, 1pt `theme.paneBorder` stroke, r8, clipped. Shadow
black at 35%, offset y 8, blur 24 on the canvas (a SwiftUI `shadow` radius of
12 renders the same spread).

**Title row:** 28 tall, fill `theme.chrome`, pad 0/12, gap 8 between its items. The title at
11.5/600 in `theme.textStrong`, truncating in the middle, reads
`<command> · <folder>` with the home folder as `~`. A 12x12 `xmark` in
`theme.textDim` at the trailing edge.

**Size control:** three buttons between the title's spacer and the `xmark`,
left to right Small (0.7 of the tab area), Medium (0.8, the default) and Large
(0.9). Each is drawn as a rounded rectangle, r1.5, that grows with its size:
10x7, 12x9 and 14x10.5. The unselected ones are a 1.25pt outline in
`theme.textDim`; the selected one is filled in `theme.accent` with no stroke.
Each button's hit area is 18x18, 2 apart, centred on the row's height, and the
group ends 10 before the `xmark`. The choice is a preference kept across modals
and launches; there is no keyboard shortcut.

**Service view:** the title row leads with "← runner" at 11/500 in
`theme.accent`, then a 1x12 rule in `theme.rule`, then the title.

**Terminal area:** fill `theme.pane`, one pane inset 6 from the box's edges.
Every hidden rt tab holds exactly one pane (a queued or preset launch runs a
runner board in the same pane), so the modal shows one surface and needs no tab
strip and no split layout. What draws inside is ghostty; the canvas's text is
illustration.

**Strip** (a command that ended): 26 tall, fill `theme.chrome`, a 1pt
`theme.rule` rule along its top edge, pad 0/12, text at 11/500: `exited…` in
`palette.red`, `finished…` in `theme.textStrong`.

## Against the plan's starting values

| Value | Plan | Canvas |
| --- | --- | --- |
| `RtModal.tabStripHeight`, `tabSpacing`, `tabHorizontalPadding`, the tab strip | a strip for items spanning tabs | none: one pane per hidden tab |
| `RtModal.backdropOpacity` | 0.45 | 0.45 dark, 0.30 light |
| `RtModal.sizeFraction` | 0.8 | 0.8; the first hand test moved it to 0.9 |
| box fraction | 0.9 | Small 0.7 / Medium 0.8 / Large 0.9, chosen in the title row, default Medium |
| `RtModal.shadowRadius` | 24 | 12 (SwiftUI radius for the canvas's blur 24) |
| strip rule | none | 1pt top `theme.rule` |
| "← runner" | text alone | text, then a 1x12 `theme.rule` divider |
| rt menu | a native `NSMenu` of text rows | a flock popover (above) |
| modal placement | over the rail and the canvas | over the tab area only (tab strip and panes) |
| runner button | a separate `selectionBg` pill, `green` dot, "runner" | none: the rt pill's second half (divider and `rt-pink` glyph) |
| rt button count | running rt run items plus one for a runner | running rt run items only |

Every other starting value in the plan matches the canvas.
