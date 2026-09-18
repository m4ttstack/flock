# Chat design measurements

Every number here was read out of `flock-chat.pen` itself, not from the PNGs and
not by eye. It is the implementation target: a view is finished when it renders
to these values.

## Tokens map to flock's own palette

The canvas was drawn with flock's palette names, so the mapping is one to one
and no colour is ever written as a literal hex in Swift.

| Canvas token | flock | tokyo-night hex |
| --- | --- | --- |
| `$panel-bg` | `palette.panelBg` | `#1A1B26` |
| `$surface-0` | `palette.surface0` | `#24283B` |
| `$surface-1` | `palette.surface1` | `#414868` |
| `$active-row` | `palette.activeRowBg` | `#232636` |
| `$selection` | `palette.selectionBg` | `#2D3650` |
| `$overlay-0` | `palette.overlay0` | `#565F89` |
| `$subtext` | `palette.subtext0` | `#A9B1D6` |
| `$accent` | `palette.accent` | `#7AA2F7` |
| `$mauve` | `palette.mauve` | `#BB9AF7` |
| `$green` | `palette.green` | `#9ECE6A` |
| `$yellow` | `palette.yellow` | `#E0AF68` |
| `$red` | `palette.red` | `#F7768E` |
| `$teal` | `palette.teal` | `#7DCFFF` |
| `$text` | `palette.text` | `#C0CAF5` |

**One token disagrees, and the palette wins.** The canvas holds `text` as
`#E6E0FF`, which is the text colour of a different document whose variables were
merged into this file; every other token matches tokyo-night exactly. `$text`
therefore means `palette.text`, and body text renders `#C0CAF5`. The approved
PNGs show the `#E6E0FF` value, so text in a render sits a shade cooler than in
the PNG beside it. That is the only colour on which a render and a PNG are
expected to differ.

Type is Inter throughout, which is what `ChromeType` already installs. A weight
of `600` is semibold, `500` is medium, `normal` is regular.

## Popover, both states

360 wide. Signed out is 325 tall, signed in is 348. Corner radius 10, fill
`panelBg`, stroke `surface1`.

| Band | Height | Padding | Gap |
| --- | --- | --- | --- |
| Header | 41 | 12 / 14 | 8 |
| Status | 45 signed out, 68 signed in | 13 / 14 / 14 / 14 | 7 |
| Label FEATURES | 33 | 14 / 14 / 7 / 14 | |
| Features | 124 | 0 / 8 | |
| Label THIS PANE | 33 | 14 / 14 / 7 / 14 | |
| Sign Buttons | 49 | 0 / 14 / 16 / 14 | 8 |

Header: title "Chat" at 14/600 in `text`, an open-viewer icon 15x15 in
`overlay0` at the trailing edge.

Status: a 7x7 dot (`green` when signed in, `overlay0` when not), the handle at
13/600 in `text`, the state word at 12/regular in `subtext0` printed exactly as
rt gives it, and a trailing pane chip 63x18, `surface0`, r4, pad 3/8, gap 5,
holding a 10x10 icon in `overlay0` and the pane name at 10/regular in `subtext0`.
Room chips sit 38 below the band top: 16 tall, `activeRowBg`, r4, pad 2/7, gap 6,
names at 10/regular in `overlay0`.

Section labels are 10/600 in `overlay0`.

Features rows: each 344x31, r5, pad 8, gap 9, inset 8 from each side. Icon 14x14,
name at 12/regular in `text`, shortcut at 10/regular in `overlay0` hard against
the trailing edge. The hovered or selected row fills `selectionBg` and its icon
turns `accent`; every other row has no fill and an `overlay0` icon. The four rows
are Broadcast to panes, Chat peek, Quick send, Open viewer, carrying `⌘⇧B`,
`⌘⇧P`, `⌘⇧S`, `⌘⇧V`.

Sign buttons: two 162x33 buttons, r6, pad 9/10, gap 7, with 13x13 icons. The
primary one fills `accent` with its icon and label in `panelBg` at 12/600; the
secondary fills `surface0` with icon and label in `subtext0` at 12/500. Signed
out puts Sign in first as primary; signed in puts Sign out second as primary.
Neither is ever hidden.

## Peek

360x326, r10, `panelBg`.

Header 41 tall with a 14x14 back chevron, "Chat peek" at 14/600, and a 14x14
close at the trailing edge, both icons `overlay0`.

Label PANES ON CHAT: 31 tall, pad 13 / 14 / 6 / 14.

Pane rows: 42 tall, pad 7/14, gap 9. A 7x7 status dot coloured by agent state
(`yellow`, `green`, `accent`, `red`), then a two-line stack with gap 1: the
handle at 12/500 in `text` and the location at 10/regular in `overlay0`. A row
with unread carries a 19x16 pill, `accent`, r8, pad 2/6, count at 10/600 in
`panelBg`; a 12x12 jump glyph in `overlay0` closes the row. Rows alternate
`activeRowBg` and no fill.

Label ROOMS: 31 tall, same padding. Room rows 28 and 27 tall, pad 6/14, gap 9,
name at 12/regular in `subtext0`, same unread pill.

## Quick send

360x234, r10, `panelBg`, stroke `surface1`. Header 41, stroke `surface0` beneath.

Target band 57 tall, pad 13 / 14 / 4 / 14, gap 7: label "TO" at 10/600 in
`overlay0`, then chips 21 tall, r4, pad 4/9, gap 6. The selected chip fills
`accent` with its name in `panelBg` at 11/600; the rest fill `surface0` with
names in `subtext0` at 11/regular. Rooms come before people and keep their
prefixes.

Field band 136 tall, pad 10 / 14 / 14 / 14, gap 9. The field is 332x74,
`surface0`, stroke `accent`, r6, pad 10/11, typed text at 12/regular in `text`.
The footer is 29 tall: the hint at 10/regular in `overlay0` reading who the
message sends as, and an 82x29 send button, `accent`, r6, pad 7/13, gap 6, label
at 12/600 in `panelBg` with `⌘⏎` beside it at 10/regular in `panelBg` at 67%.

## Broadcast

400x370, r10, `panelBg`, stroke `surface1`. Header 41 with stroke `surface0`.

Select head 31 tall, pad 13 / 14 / 6 / 14: "PANES" at 10/600 in `overlay0` and
"Select all" at 10/regular in `accent` at the trailing edge.

Pane rows 42 tall, pad 7/14, gap 10. A 15x15 checkbox, r3: checked fills `accent`
with a 10x10 tick in `panelBg`, unchecked is empty with a `surface1` stroke. Then
the 7x7 status dot and the same two-line stack as peek.

Field band 130 tall, pad 14, gap 9, stroke `surface0` above. Field 372x64, same
treatment as quick send. Footer hint counts the selected panes. The send button
is 112x29 and fills `mauve`, not `accent`.

## Menu bar

300x203, r8, pad 6, fill `#20212E`, stroke `surface1`. Items 288x27, r4, pad 6/9,
gap 10, labels at 12/regular in `text`, shortcuts at 11/regular in `overlay0`.
Separators are 1pt in `surface0`, after Chat Panel and after Open Viewer. A
disabled item takes `overlay0` for its label, which is what Sign Out This Pane
shows when the focused pane is not signed in.

Order and keys: Chat Panel `⌘⇧C`, then Broadcast to Panes… `⌘⇧B`, Chat Peek
`⌘⇧P`, Quick Send… `⌘⇧S`, Open Viewer `⌘⇧V`, then Sign In This Pane `⌘⇧I` and
Sign Out This Pane `⌘⇧O`.

## The chat button in a pane's chrome

The chrome row is 32 tall with pad 7/10 and gap 8; the button sits at y 7 and the
status dot stays to its right.

- **Signed in:** 71x18, fill `selectionBg`, stroke `accent`, r4, pad 3/8, gap 6,
  the handle at 10/600 in `accent`.
- **Signed out:** 27x17, fill `surface0`, r4, pad 3/8, gap 6, glyph only.
- **No chat binary:** no button.
