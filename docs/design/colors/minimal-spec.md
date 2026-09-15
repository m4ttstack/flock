# Minimal chrome: approved spec

Approved by Matt 2026-09-15 in Pen. Source of truth: `paddock-colors.pen`, frame
**Minimal window** inside the board "Chrome contrast pass". Reference render:
`minimal-approved.png`. The Now / Proposed / Stronger columns on the same board
are history, kept for comparison only.

## Palette (Tokyo Night)

Every color in the approved window resolves to one of these roles. Nothing is
hardcoded outside them.

| Role | Hex | Used for |
|---|---|---|
| chrome | `#14151B` | title bar, sidebar, tab strip: one surface |
| rule | `#363948` | sidebar rule, tab strip bottom rule |
| canvas | `#2E303D` | the work surface behind panes, one step above chrome |
| pane | `#191A22` | pane background, identical to the terminal ground |
| paneBorder | `#50556A` | unfocused pane outline |
| tabRest | `#262835` | unselected tab block |
| selection | `#2B3A62` | selected tab block AND selected workspace row |
| textStrong | `#E6E7EB` | selected tab and workspace labels, focused pane title, window title |
| textDim | `#D0D2DC` | unselected tab and workspace labels, unfocused pane title |
| textLabel | `#A3AACB` | WORKSPACES heading, counts, tab status dots at rest, protocol readout, divider handle |
| accent | `#7AA2F7` | selected tab underline, selected workspace indicator, focused pane border |

Terminal content colors are untouched.

### Contrast (WCAG ratio)

rule/chrome 1.59, canvas/chrome 1.39, pane/canvas 1.33, paneBorder/canvas 1.77,
tabRest/chrome 1.25, selection/chrome 1.63, textStrong on selection 9.02,
textDim on tabRest 9.69, textLabel on chrome 7.95, textLabel on canvas 5.71,
accent on chrome 7.23.

### Deriving the roles for every theme

`Theme.swift` derives chrome roles as per-channel offsets from each theme's
`panelBg`. Against Tokyo Night's `panelBg` (26, 27, 38) the approved values are:

| Role | Offset from panelBg |
|---|---|
| chrome | (-6, -6, -11) |
| rule | (28, 30, 34) |
| canvas | (20, 21, 23) |
| pane | (-1, -1, -4), already `terminalGround` |
| paneBorder | (54, 58, 68) |
| tabRest | (12, 13, 15) |
| textStrong | (204, 204, 197), already `chromeTextStrong` |
| textDim | (182, 183, 182) |
| textLabel | (137, 143, 165) |

`selection` is the accent laid over chrome, not an offset: it has to carry the
theme's own accent hue. Tokyo Night lands on `#2B3A62`; use that exact value
there and an accent-over-chrome blend (about 27 percent) for other themes.

Light themes (Catppuccin Latte, Tokyo Night Day) cannot take these offsets as
written: adding brightness to a light `panelBg` clamps to white. Their offsets
must run in the opposite direction (chrome slightly darker than panelBg becomes
chrome slightly lighter, text offsets become darkening). Verify each light theme
on a capture rather than trusting the arithmetic.

## Geometry

| Element | Value |
|---|---|
| Title bar | 20pt tall; window buttons 12pt, vertically centered; title 9pt medium, centered |
| Sidebar | 150pt wide, padding 10 vertical / 8 horizontal, 1pt row gap, 1pt rule on its right edge |
| WORKSPACES heading | 8pt semibold, letter spacing 1, 6pt below it before the first row |
| Workspace row | padding 4 / 8, gap 6, corner radius 2; 2x12pt indicator bar keeps names aligned: accent when selected; on other rows the workspace's agent status in the tab dot colors (blocked red, done teal, working yellow, most urgent first), clear when idle or unknown; name 11pt (medium when selected); count 9pt, right-aligned |
| Tab strip | 28pt tall, padding 0 / 8, 2pt gap between tabs, tabs bottom-aligned, 1pt rule under the strip |
| Tab | 78pt wide, 22pt tall, square corners, padding 0 / 9, gap 5; label 11pt (medium when selected), left-anchored; 5pt status dot after the label |
| Selected tab | selection fill, 2pt accent underline at the bottom; unselected tabs have no underline slot at all |
| Protocol readout | 9pt monospace, right side of the strip |
| Canvas | 5pt padding around the panes |
| Gap between panes | 7pt |
| Divider handle | 1.5pt by 40pt, radius 0.75, centered in the gap |
| Pane | corner radius 2, 1pt border (focused pane: 1pt accent), padding 8 / 10; title 9pt medium |

## Implementation notes

- The 7pt gap replaces `DividerBand.gutter` (12). The grab band's half must still
  clear the tightest neighbouring inset; recheck `DividerBandTests` against the
  new gutter and the pane's new 8 / 10 padding before trusting it.
- On a 1x display a 1.5pt handle cannot sit on whole pixels and renders as a soft
  2px line; 1pt is the crisp fallback if it reads fuzzy.
- The 20pt title bar means repositioning the macOS window buttons in AppKit and
  reapplying that after resize and full screen, since their default position
  assumes a taller bar.
