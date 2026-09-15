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

The design frame is authored at 1x and the app implements it at 1.28x, the
scale it was approved at: every value below is the design's times 1.28, rounded
to a whole point (text to the half point), except 1pt rules and borders.

| Element | Value |
|---|---|
| Title bar | 26pt tall; window buttons vertically centered; title centered, 1.5pt below the bar's center |
| Sidebar | 192pt wide, padding 13 vertical / 10 horizontal, 1pt row gap, 1pt rule on its right edge |
| WORKSPACES heading | 8pt below it before the first row |
| Workspace row | padding 5 / 10, gap 8, corner radius 3, 17pt content band (27pt row, 28pt pitch); 3x15pt indicator bar keeps names aligned: accent when selected; on other rows the workspace's agent status in the tab dot colors (blocked red, done teal, working yellow, most urgent first), clear when idle or unknown; count right-aligned |
| Tab strip | 36pt tall, padding 0 / 10, 3pt gap between tabs, tabs bottom-aligned, 1pt rule under the strip |
| Tab | 100pt wide, 28pt tall, square corners, padding 0 / 12, gap 6; label left-anchored; 6pt status dot after the label |
| Selected tab | selection fill, 3pt accent underline at the bottom; unselected tabs have no underline slot at all |
| Protocol readout | right side of the strip, 1.5pt above the strip's center |
| Canvas | 6pt margin around the panes |
| Gap between panes | 9pt; grab band 28pt centered on it |
| Divider handle | 2pt by 51pt, fully rounded, centered in the gap |
| Pane | corner radius 3, 1pt border (focused pane: 1pt accent), padding 10 / 13; 14pt title row, 4pt above the terminal |
| Drag visuals | overlay, ghost, flash and toast radii 3; insertion bar 3pt with a 10pt end dot and 4pt overhang; drop zone margin 10, minimum run 56; ghost capped at 333x205, floored at 192x41; scroll thumb 5pt wide, 15pt minimum |

## Typography

Chrome text is **Inter** (4.1 static faces, bundled and registered at launch).
Monospaced chrome text is the **terminal face**: the `font-family` the user's
Ghostty config names when CoreText resolves it (JetBrainsMono Nerd Font on the
reference machine), else Menlo, exactly as the panes resolve it. SF Symbols stay
in the system face. Text uses the system's normal font smoothing.

| Text | Face | Size | Weight |
|---|---|---|---|
| Window title | Inter | 11.5pt | medium |
| WORKSPACES heading | Inter | 10pt, tracking 1.28 | semibold |
| Workspace name | Inter | 14pt | regular, medium when selected |
| Workspace count | Inter | 11.5pt | regular |
| Tab label | Inter | 14pt | regular, medium when selected |
| Pane title | Inter | 11.5pt | medium |
| Protocol readout, pane status chip | terminal face | 11.5pt | regular |
| Status card path and last line | terminal face | 13pt | regular |
| Connection notice, card and launcher hints | Inter | 11.5pt | regular |
| Banner, toast message | Inter | 14pt | regular |
| Copied whisper | Inter | 13pt | regular |
| Ghost label | Inter | 14pt | semibold |
| Divider ratio label | Inter | 13pt | semibold |
| Launcher harness name | Inter | 16.5pt | medium |
| Launcher monogram | Inter | 14pt | bold |
| Empty canvas | Inter | 15.5pt | regular |

## Implementation notes

- Sizes live in one place each: `ChromeMetrics` (window chrome), `PaneChrome`
  (pane box), `DividerBand` (gutter and handle), `ChromeType` (faces and sizes).
- The 9pt gap is `DividerBand.gutter`, split 4 leading / 5 trailing so box edges
  stay whole; canvas padding 2 / 1 keeps the outer margin at exactly 6. The grab
  band's half (14) stays inside the tightest neighbouring inset (half gap 4.5
  plus bottom padding 10); `DividerBandTests` pins it.
- The 26pt title bar means repositioning the macOS window buttons in AppKit and
  reapplying that after resize and full screen, since their default position
  assumes a taller bar. The system title bar (32pt) still reaches the top of the
  tab strip, which `WindowDragExclusion` keeps from moving the window.
