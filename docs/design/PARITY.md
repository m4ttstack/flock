# Visual parity checklist

Element-by-element values extracted from the artboard sources (`src/*.dc.html`).
UI implementers verify against this list by sampling pixels from a window
capture, not by eyeballing. Values are the tokyo-night rendering; every chrome
value maps through a Theme role (named in parens), never a hardcoded hex in
views. Task reviewers treat a missing row or an unsampled claim as a finding.

## Window chrome

| Element | Value (tokyo-night) | Theme role |
| --- | --- | --- |
| Window / canvas background | `#1E1F28` | windowBg |
| Titlebar | single 44px bar, traffic lights ON it (no system strip), bottom border | windowBg-family + border |
| Sidebar (workspace rail) | `#16171E`, 216px wide, right border | sidebarBg |
| Tab strip | `#1B1C24`, 42px tall, bottom border | stripBg |
| All 1px borders/dividers | `#2A2C37` | border |
| Pane ground | `#191A22` | terminal ground (constant until live content) |
| Pane header | `#20212B`, 28px tall, 1px bottom border | paneHeaderBg + border |
| Pane corner radius | 9px (cells), 12px (window) | - |
| Pane gutters | 6px | - |
| Focused pane | 2px accent ring + 3px halo at 18% accent | accent |
| Selected rail row | accent at 16% fill, 35% border, 8px radius | accent |
| Selected tab pill | fill `#2A2C37`, border `#3A3D4A`, 7px radius, label `#E6E7EB` semibold; unselected label `#9B9DA9`; count chip on selected pill `#1E1F28` | tabPillSelectedBg / tabPillSelectedBorder / chromeTextStrong / chromeTextDim / windowBg |

## Status dots (herdr parity)

| State | Color role | Fill |
| --- | --- | --- |
| working | yellow | filled |
| blocked | red | filled (+ glow when attention) |
| done | teal | filled |
| idle | green | HOLLOW ring (1.5px stroke) |
| unknown | overlay0 | small centered dot |

Sizes: 8px pane header / rail, 7px tab pill / titlebar, 6px thumbnails.
Titlebar connection dot is filled green (connection health, not agent status).
Zoom badge: mauve, never a status color.

## Type

| Element | Size / weight |
| --- | --- |
| Window title, rail rows | 13px semibold / regular |
| Tab labels | 12px (semibold selected) |
| Pane header title | 11px semibold |
| cwd tails, protocol readout | 10-11px mono |
| Section label (WORKSPACES) | 10px bold, 0.08em tracking |
| Status chips | 9px mono, 14% tint bg, 4px radius |

## Verification recipe

1. Launch against a seeded scratch session, capture: `screencapture -l <windowID> out.png`.
2. Sample each chrome row's hex at a known point (Retina: logical points x2)
   programmatically (PIL / CGImage script) and compare exactly.
3. Check structural rows (heights, borders present, radii, dot fills) against
   the capture at 2x zoom.
4. Evidence (sampled values table) goes in the task report.

## Task 18c evidence: selected tab pill

Computed (theoretical) values, verified by direct arithmetic against
`Theme`'s `chromeOffset(panelBg, delta)` formula for tokyo-night
(`panelBg = (26, 27, 38)`):

| Role | Delta | Computed | Target |
| --- | --- | --- | --- |
| tabPillSelectedBg | (16, 17, 17) | `#2A2C37` | `#2A2C37` |
| tabPillSelectedBorder | (32, 34, 36) | `#3A3D4A` | `#3A3D4A` |
| chromeTextStrong | (204, 204, 197) | `#E6E7EB` | `#E6E7EB` |
| chromeTextDim | (129, 130, 131) | `#9B9DA9` | `#9B9DA9` |

All four match the reference exactly by construction. Pixel-sampled from
`docs/design/parity/task-18c-smoke.png` (PIL, same recipe as above): the
selected pill's fill sampled `(37, 39, 48)` against a computed `(42, 44, 55)`
-- a consistent `(-5, -5, -7)` offset also reproduced when re-sampling the
UNCHANGED `paneHeaderBg` role (`(29, 30, 38)` sampled vs `(32, 33, 43)`
computed) in the same capture, so it is the capture pipeline's color
management (this display is P3; `screencapture`'s raw channel values read
naively as sRGB), not an implementation defect in the new roles.

## Checkpoint 2b evidence: ghostty renderer parity (parity/checkpoint-2b/launch.png)

Tokyo-night, seeded scratch session, focused pane = libghostty surface,
unfocused = SwiftTerm observe. Sampled sRGB-converted (display is P3; +-1
channel offsets are the documented capture-pipeline artifact, not drift):

| Point | Sampled | Reference | Verdict |
|---|---|---|---|
| Titlebar bg | #1E2028 | #1E1F28 | ok (P3 +-1) |
| Rail bg | #17181E | #16171E | ok (P3 +-1) |
| Tab strip bg | #1C1C24 | #1B1C24 | ok (P3 +-1) |
| Selected pill fill | #2A2C37 | #2A2C37 | EXACT |
| Selected pill label | #E6E7EB | #E6E7EB | EXACT |
| Pane header bg | #20212B | #20212B | EXACT |
| ghostty terminal ground | #191A22 | #191A22 | EXACT |
| SwiftTerm terminal ground | #191A22 | #191A22 | EXACT |

The two renderers painting an identical ground was the port's visual bar:
the themed ghostty config (background/foreground/palette) lands the same
hex the SwiftTerm path ships.

Known artifacts on the capture, for the checkpoint hands-on pass: a stray
hollow-box glyph mid-pane in the unfocused SwiftTerm pane (pre-existing
observe-path rendering, unchanged by the port) and that pane's thin scroller
line at its right edge.

## Checkpoint 2c evidence: single renderer (parity/checkpoint-2c/single-renderer.png)

Both panes are libghostty surfaces (unfocused = observe-mode bridge,
focused = control-mode). Chrome samples unchanged from 2b (titlebar
#1E2028, rail #17181E, tab strip #1C1C24, pane header #20212B). Visible in
the frame: identical face and pitch in both panes, the unfocused pane's
hollow cursor at its real prompt row (the 2b stray-glyph artifact is gone
with SwiftTerm), and the tail of a 100k-line stream that was flipped
mid-output without corruption.
