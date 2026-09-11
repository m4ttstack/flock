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
| Selected tab pill | one surface step above strip, 1px border, 7px radius | surface roles |

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
