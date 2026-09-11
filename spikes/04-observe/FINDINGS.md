# Spike 04: observe streams into SwiftTerm at scale + backfill

Probe code: `spikes/04-observe/Sources/main.swift` (SPM executable, three modes:
`bridge`, `scale`, `backfill`), plus `spikes/04-observe/seed-scale.sh` (layout
seeding) and `spikes/04-observe/measure-scale.sh` (ps sampling driver). All
runs used a dedicated scratch herdr session
(`spikes/lib/scratch-session.sh start obs04`, herdr 0.9.0 / protocol 22),
never the default socket. Session and every seeded pane/loop were torn down
at the end (`scratch-session.sh stop`); see Cleanup below.

## SwiftTerm version pin

`https://github.com/migueldeicaza/SwiftTerm`, tag `1.20.0`
(revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`), pinned exact in
`Package.swift` and recorded in `Package.resolved`. This is the version to
carry into the real app (Task 18).

## Exact SwiftTerm API surface that worked

The brief's skeleton is close but one parameter name is wrong:

- `Terminal(delegate: TerminalDelegate, options: TerminalOptions(cols:rows:))`
  works as shown. Only `send(source:data:)` is a required `TerminalDelegate`
  method; every other protocol method has a do-nothing default in a public
  extension, so a `NullTerminalDelegate` implementing only `send` is correct
  and sufficient.
- `term.feed(byteArray: [UInt8])` works as shown.
- `term.getLine(row: Int) -> BufferLine?` works as shown.
- `BufferLine.translateToString(...)` takes **`trimRight:`**, not
  `trimmingRight:` as the brief's skeleton names it. Signature actually is
  `translateToString(trimRight: Bool = false, startCol: Int = 0, endCol: Int
  = -1, skipNullCellsFollowingWide: Bool = false, characterProvider: ((CharData)
  -> Character)? = nil) -> String`.
- `term.resetToInitialState()` exists and works as shown.
- Cell styling: `BufferLine` has a public `subscript(Int) -> CharData`, and
  `CharData.attribute.fg` (an `Attribute.Color` enum: `.ansi256(code:)`,
  `.trueColor(r:g:b:)`, `.defaultColor`, `.defaultInvertedColor`) is how the
  probe verified SGR colors survived a backfill feed (see Step 3).

## Step 1: bridge (observe -> SwiftTerm `Terminal`)

**Verdict: PASS**, with two real caveats recorded below.

Setup: scratch workspace `w1`, tabs `tabA` (`p1`,`p2` split right) and `tabB`
(`p3`). Bridged `herdr terminal session observe <pane> --cols <c> --rows <r>`
as a child process into a headless `Terminal`, feeding NDJSON frames (reset
on `full`), and compared `screenText()` (`getLine(row:)?.translateToString
(trimRight: true)` joined) against `herdr pane read <pane> --source visible`
for the same pane.

- **Colored `printf` pane (`p1`)**: after matching the observe `--cols/--rows`
  to the pane's real size (see Caveat 1 below), `screenText()` matched
  `pane read --source visible` byte-for-byte except for the emoji drop
  (Caveat 2) and herdr's trailing-blank-row truncation (Caveat 3).
- **`vim` alt-screen pane (`p3`, 60x40)**: `diff` between `screenText()`
  (blank-trimmed) and `pane read --source visible` was **empty** -- exact
  match, including all 34 `~` filler rows and the vim status line.

### `full` frames: reset required, cumulative otherwise

`full` frames are complete from-scratch screen paints (not diffs against
prior terminal state); the probe calls `term.resetToInitialState()` whenever
`frame["full"] == true` before feeding. Non-full frames apply on top of
existing state without a reset. Every steady pane observed here only ever
sent a single `full` frame at attach time (idle panes produce no further
frames), so incremental-diff framing was not exercised by this spike; that
is real content for Task 17/18 to verify against a pane that is actively
producing new terminal output after attach.

### Caveat 1 (important): observe `--cols/--rows` mismatched to the real pane crops top-anchored, not tail-anchored

The single biggest surprise of this spike. `herdr pane get` does not expose
the pane's column width (only `scroll.viewport_rows` for height), so the
probe first tried a hardcoded `--cols 80 --rows 24`. On a pane whose real
size was 40 rows (confirmed via `stty size` run inside the pane, since it's
the only way to get width), the observe stream's `full` frame did **not**
show the bottom 24 rows (the live/cursor end, i.e. what the user is actually
looking at) -- it showed the **top** 24 rows of the real 40-row grid,
silently discarding the bottom 16 rows including the cursor and prompt.
Confirmed reproducible: raw NDJSON decode showed content lines 567-590 of a
600-line generated stream when the real visible content (at real size 40)
was lines 567-600 plus trailing status/prompt lines.

Checked whether this is a live PTY resize of the real pane: `pane.get`
during an in-flight mismatched observe still reported `viewport_rows: 40`
unchanged, so the pane itself is not resized. Herdr's observe path is doing
its own reflow/crop to the requested size, anchored at the top of the
buffer, not at the cursor/tail. **Practical rule for Task 17/18: always
discover the pane's real size first (e.g. `stty size` run in-pane, or
whatever authoritative source ships before then) and pass matching
`--cols/--rows` to observe.** Once cols/rows were matched to the pane's real
size in this spike (60x40 for the vim pane, 120x40 for the backfill pane),
every subsequent comparison in this file was an exact (or near-exact, per
Caveats 2-3) match.

### Caveat 2: an astral-plane (4-byte UTF-8) emoji is silently dropped

A shell prompt segment (a rocket emoji, `U+1F680`, raw bytes `f0 9f 9a 80`)
present verbatim in `pane read --source visible --raw` output (confirmed via
hex dump) renders as nothing (not even a placeholder glyph, cell reads as an
untouched blank) after being fed through `term.feed(byteArray:)` in this
SwiftTerm version. Reproduced twice, on two different panes, same character.
Not investigated further at the SwiftTerm-internals level (out of scope for
a spike time-box), but this is a real, load-bearing gap for Task 18 if any
pane content can contain 4-byte UTF-8 (emoji, some CJK extension planes):
**do not assume SwiftTerm's headless `Terminal` renders arbitrary Unicode
identically to herdr's own text reader.** ASCII, SGR 256-color and basic
BMP content all rendered correctly in every test here.

### Caveat 3: `translateToString(trimRight:)` and `pane read`'s blank-row handling diverge

`trimRight` only trims cells whose character code is literally `0` (an
untouched/never-written cell) -- see `BufferLine.getTrimmedLength()`. A row
that was explicitly painted with space characters (common: shell themes
that fill a line with background color) is not trimmed, so `screenText()`
rows can carry trailing padding out to the full column width even though
they look "blank." Separately, `herdr pane read --source visible` drops
**fully blank trailing rows** from its output entirely (a 40-row pane with
4 lines of real content returns 4 lines, not 40), while `screenText()`
always returns exactly `term.rows` lines. Neither is a bug; both are just a
different truncation convention. Task 18 should normalize both sides
(trim trailing all-blank rows, and consider trimming ' '-only cells) before
doing any exact-match comparison or diffing against herdr's own read paths.

## Step 2: scale probe (1 / 10 / 30 concurrent observe children)

**Verdict: PASS at all three scales, with no degradation observed up to 30.**
Steady-state total CPU stayed under 1% of one core in every case (far under
the <100%-of-one-core bar) and RSS growth flattened within the first ~10s
and stayed flat for the rest of the 60s window (bounded, not a leak).

Seeded via `seed-scale.sh`: a dedicated workspace, 6 tabs x 5 panes (splits:
right, down, down, right off each tab's root), 30 panes total, each running
`while true; do date; sleep 0.3; done`. All 30 splits succeeded (no
too-small-split rejections) since each tab was closer to a full 120x40 area.
Measured via `measure-scale.sh`: spawns the Swift probe in `scale` mode
(N observe children + N `Terminal`s in one process), samples `ps -o
%cpu=,rss=` for the probe process and every observe child every 10s for 60s.

| panes | total steady CPU (%, t=51s) | total RSS (t=0s, KB) | total RSS (t=51s, KB) | RSS delta |
|---|---|---|---|---|
| 1  | 0.0 | 19,824  | 20,256  | +432 (+2.2%)  |
| 10 | 0.1 | 99,488  | 101,168 | +1,680 (+1.7%) |
| 30 | 0.6 | 274,608 | 278,592 | +3,984 (+1.5%) |

(Startup-instant CPU, t=0s, was higher -- 1.7% / 8.8% / 22.8% total -- purely
from process spawn and initial full-frame paint; it settles to near-zero
within the first 10s sample in every case.)

**Where degradation starts: not observed at this scale with this workload.**
This synthetic workload (a `date` line + 0.3s sleep per pane, i.e. ~3 tiny
writes/sec/pane) is light: an idle-ish agent/CLI pane in practice would
produce more frequent and larger diffs. 30 panes did not stress the <100%
bar at all (0.6% total, ~170x margin), so this spike does not by itself
locate the real ContentPlane LRU cap -- it only shows 30 is comfortably
inside the safe zone. Recommend either a materially heavier synthetic load
(higher-frequency writes, larger payloads e.g. wrapped color text) or
production telemetry to actually find the degradation knee for Task 17's
cap; extrapolating linearly from these numbers, several hundred panes of
this exact workload would still fit under one core, but that extrapolation
should not be trusted over a real measurement at higher N.

No dropped/late frames were observed (each child's per-pane frame count was
inspected via the `frame_count` lines the scale mode prints; all panes that
were still producing output showed nonzero, monotonic-looking counts,
`closed: false` throughout the run).

## Step 3: backfill probe

**Verdict: PASS.** `pane.read {source:"recent", format:"ansi", lines:1000}`
on a 600-line colored-history pane (six-color SGR cycle, deliberately
matching pane read's own `--source recent --format ansi --lines N` CLI
form), fed into a fresh `Terminal` before attaching observe:

- **Styled rendering confirmed at the cell level, not just as raw text.**
  Added a `rowColors()` helper that reads `term.getLine(row:)?[0].attribute.fg`
  for every row after backfill-feeding; output was
  `ansi256(4)|ansi256(5)|ansi256(6)|ansi256(1)|ansi256(2)|ansi256(3)|...`
  cycling exactly as the generator's `printf "\033[%sm..."` color rotation
  intended, before falling to `default` on the trailing warning/prompt rows.
  This proves SwiftTerm's headless `Terminal` genuinely tracks per-cell SGR
  attributes through a large backfill feed, not just plain text.
- **Seam quality**: once observe's `--cols/--rows` were matched to the
  pane's real size (120x40, discovered via in-pane `stty size` per Caveat 1),
  attaching observe on top of the backfilled `Terminal` (no reset, since the
  first live frame is itself a `full` frame that fully repaints from the
  same real screen state) produced a screen that was byte-identical to
  `pane read --source visible` except for the same known emoji-drop
  (Caveat 2). No visible tear, no duplicated or missing lines at the
  boundary between backfilled history and the live frame. **Before the
  cols/rows fix**, the seam was badly torn: the first live `full` frame
  showed a completely different, older top-cropped window (Caveat 1),
  which would have looked like "backfill overwritten by garbage" if not
  understood as the cols/rows mismatch. This reinforces Caveat 1 as the
  single most load-bearing thing to get right for Task 18's backfill path.

### Alt-screen (vim) case: `lines:1000` vs `lines:viewport_rows`

Ran on the same `vim` pane from Step 1 (real size 60x40, alt-screen active).
`pane read --source recent --format ansi --lines 1000` and `--lines 40`
(viewport_rows) returned **byte-identical** output (`diff` clean), both
completing in ~6-12ms with no observable delay difference, and
`pane.get.scroll.max_offset_from_bottom` stayed `0` across both reads.

This matches the brief's predicted footgun exactly, for the reason the brief
names: the harvest/synthetic-wheel-scroll behavior that can jerk a live
viewport gates on herdr recognizing an idle *agent* in the pane, and a
scratch `vim` is not a recognized agent. So for this alt-screen case herdr
just returns the on-screen alt-buffer content directly regardless of the
requested `lines`, with **no jerk and no synthetic scroll**. **This is not
full verification of the real footgun** -- it only shows the safe,
unrecognized-pane path. Real verification (does a *recognized* agent's
alt-screen pane actually get wheel-scrolled and jerk the live view for a
large `lines` request) is out of scope here per the brief and lands in the
e2e phase, ideally against a scripted fake-agent that herdr's agent
detection actually recognizes.

**Safe backfill recipe recorded for Task 18**: when the target pane is
alt-screen and not a recognized agent, `lines` can safely be the larger of
the two values (1000) with no different behavior than requesting exactly
`viewport_rows` -- so there is no reason to under-request. When the target
pane *is* a recognized agent, treat a large `lines` value as unverified and
risky until the e2e phase confirms whether it triggers a jerk; the
conservative interim rule is to request `lines: viewport_rows` (or less)
against recognized-agent panes until that's proven safe.

## Surprises for Tasks 17/18 (summary)

1. **Observe `--cols/--rows` must match the pane's real size**, discovered
   via in-pane `stty size` since `pane.get` does not expose width. A
   mismatch does not resize the real pane, but silently top-crops the
   observed content away from the cursor/tail -- the worst possible failure
   mode for a live content pane, since it looks like a stale/frozen view
   rather than an obvious error.
2. **SwiftTerm 1.20.0 drops at least one astral-plane (4-byte UTF-8) emoji**
   fed via `feed(byteArray:)`. Needs a follow-up spot-check against a wider
   character set before Task 18 treats it as fully general-purpose.
3. **`translateToString(trimRight:)` and herdr's blank-row/whitespace
   conventions are not identical** -- normalize before diffing.
4. **The brief's skeleton has one wrong parameter name**
   (`trimmingRight` -> `trimRight`); otherwise it is accurate, including that
   only `send` is a required `TerminalDelegate` method.
5. **The scale probe did not find a real degradation ceiling** at 30 panes
   with a light synthetic workload; Task 17's actual LRU cap needs either a
   heavier synthetic load or production data, not just this number.

## Cleanup

All panes, the observe child processes, the 30 `date`-loop shells, and the
`vim` process were torn down before finishing: vim was quit via
`pane send-keys .. Escape` + `:q!` + `Enter`, and the entire scratch herdr
session (workspace, tabs, panes, and their child processes) was removed via
`spikes/lib/scratch-session.sh stop obs04`. Post-cleanup checks: `pgrep -f
"while true; do date"`, `pgrep -f PaddockObserveSpike`, `pgrep -f "terminal
session observe"` all empty; `~/.config/herdr/sessions/` no longer contains
`paddock-obs04`.
