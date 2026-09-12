# Spike 08: herdr control-transport semantics (task 18d)

Probe code: `control_probe.py` (subprocess/NDJSON helpers), `pty_spawn.py` (real
pty with an explicit winsize, needed because this sandbox's own stdin is not
a tty), `run_probes.py` (steps A/C/D), `step_b_tui.py` (step B, the live TUI
takeover check), `step_e_cost.py` (step E, input-forwarding sanity + 8-pane
cost). All runs used a dedicated scratch herdr session
(`spikes/lib/scratch-session.sh start ctl-probe`, herdr 0.9.0 / protocol 22),
reseeded fresh via `spikes/lib/seed-layout.sh` before each run; never the
default socket. Session and every seeded workspace/pane were torn down at the
end (`scratch-session.sh stop ctl-probe`); see Cleanup below.

herdr source lives at `~/Documents/GitHub/herdr` and was read only, never
edited.

## Q1: does `takeover=true` kick, freeze, or coexist with a live TUI attach?

**Answer: takeover always KICKS a same-terminal direct-attach/control owner
(clean `ServerShutdown`, not a freeze), and NEVER affects the ordinary
full-screen herdr TUI (`herdr --session <name>`), which is a structurally
different client mode.**

Source: `ClientControlTerminal` and `ClientAttachTerminal` (`herdr terminal
attach`) both funnel into the same `attach_terminal_client`
(`src/server/headless.rs:1776-1879`, `control_terminal_client` at
`headless.rs:1390-1397` just resolves the target string then calls it). Two
disjoint modes exist on `ClientConnectionMode`
(`src/server/clients.rs:12-17`): `ClientShell` (the ordinary multi-pane TUI)
vs `TerminalAttach`/`TerminalObserve` (direct terminal attach/control/observe).
Ownership is tracked only in `terminal_attach_owners: HashMap<String, u64>`
(`headless.rs:232`), keyed by `terminal_id`, and is populated/consulted only
by `attach_terminal_client` (`headless.rs:1826-1848`) and the alt-screen-read
gate (`headless.rs:2732`, `2780`) -- **`ClientShell` never touches this map**,
so a normal TUI attach is not a party to takeover contention at all.

`attach_terminal_client`'s logic (`headless.rs:1826-1848`): if an
`existing_owner` is present and `takeover` is false, the new client is
rejected with `ServerShutdown{"... already has an attached client; retry
with --takeover"}` and disconnected -- the new client dies, the old one is
untouched. If `takeover` is true, the *existing* owner is sent
`ServerShutdown{"terminal attach taken over"}` and disconnected, and the new
client becomes the sole owner. There is no third state; ownership is always
exclusive per `terminal_id`.

Live confirmation (`run_probes.py`, step A on a fresh `w1:p1`):
- Non-takeover second client while a first control client (`a`) is attached:
  rejected instantly -- `{"reason":"terminal attach failed: terminal
  term_65b3ecb4807631 already has an attached client; retry with
  --takeover","type":"terminal.closed"}`, `a` untouched (`a_exit=null`,
  still alive).
- Takeover client (`c`) on the same target: `a` received one more frame then
  `{"reason":"terminal attach taken over","type":"terminal.closed"}` and
  exited cleanly (`a_exit=0`); `c` stayed attached (`c_alive=true`) and its
  input landed (`pane.read` showed `TAKEOVER_SURVIVOR_OK` echoed back).

Live confirmation the ordinary TUI is untouched (`step_b_tui.py`): spawned
the real `herdr --session ctl-probe` app on a genuine pty (`pty_spawn.py`,
needed since `script -q` inherits this sandbox's zero winsize and herdr
rejects that -- "terminal reported a zero-sized grid"; also needed
`HERDR_ENV` unset per client, since this whole task is itself running
inside a real herdr pane and herdr refuses nested launches by default,
`src/main.rs:443-449`), focused on `w1:p1`, then took over that exact pane
from a control channel:

```
tui alive before takeover: True
tui painted 1024 bytes before takeover
control channel attached ok, first line type: terminal.frame
tui alive after takeover: True
tui produced 1024 more bytes after takeover (repaint still flowing)
pane still present after takeover: {... 'pane_id': 'w1:p1', 'focused': True, ...}
```

The TUI process never exits, never errors, and keeps repainting. **Source
and live agree exactly: no disagreement to flag.**

Ruling for 18f: the bridge should always pass `--takeover`. It only ever
competes with a *stale prior paddock bridge* on the same pane (which it
should reclaim) and never with the human's real herdr session.

## Q2: does `terminal.resize` on the control channel resize the REAL pane?

**Answer: yes -- it resizes the actual pane runtime, not just the
requesting client's view.**

Source: `ServerEvent::ClientResize` (`headless.rs:2166-2224`). For a client
in `TerminalAttach` mode (which is what both `ClientControlTerminal` and
`ClientAttachTerminal` produce), the handler calls `runtime.resize(rows,
cols, ...)` directly on `self.app.terminal_runtimes.get(&terminal_id)`
(`headless.rs:2200-2203`) -- the same runtime object every other reader of
that pane (including the ordinary TUI's paint of that pane) uses. For a
client in `TerminalObserve` mode, the same event only updates the client's
own `terminal_size`/`cell_size` fields (`headless.rs:2206-2222`) and never
touches `runtime` at all.

Live confirmation (`run_probes.py`, step C): pane `w1:p1` started at
`viewport_rows: 24` (from `pane.get`, a global/authoritative read, not a
per-client one). A control-channel `terminal.resize {cols:100, rows:35}`
changed `pane.get`'s `viewport_rows` to `35`. Opening a separate `observe`
client afterward with `--rows 44` left `viewport_rows` at `35` (unchanged --
observe's own requested size never reached the real pane). Source and live
agree.

Ruling for 18f/18h: this is intended and desired -- paddock's ghostty
surface computing exact cols/rows and pushing them through `terminal.resize`
really does make the herdr pane fit paddock's window, which is the whole
point of the port. The flip side: whoever else is looking at that pane (a
live TUI, in particular) sees the SAME resize, same as it would for any
other direct-attach client today; this is an accepted, already-shipped-by-
Herdglass behavior, not a new risk.

## Q3: is `ClientAttachScroll` per-attach-client or the shared real viewport?

**Answer: shared real viewport. This is the opposite of the study's
hypothesis, and it directly triggers the "never yank Matt's viewport" spec
rule -- the FIFO scroll path as designed in Herdglass is unsafe to port
as-is.**

Source: `apply_terminal_attach_scroll` (`src/server/pane_input.rs:106-126`)
calls `runtime.scroll_up`/`scroll_down`/`scroll_reset`
(`src/pane/terminal.rs:1743-1767`), which mutate `core.terminal` via
`ghostty_set_scroll_offset_from_bottom` -- the ONE ghostty terminal core
object owned by the pane, the same object every rendering path (the ordinary
TUI's paint of that pane box, any observe client, any attach client) reads
from. There is no per-`client_id` scroll offset anywhere in this path; it is
plain pane-runtime state, exposed authoritatively via `pane.get`'s
`scroll.offset_from_bottom` field, which is itself a strong tell: a
genuinely per-client value would never surface on the pane object a
`pane.get` returns.

Live confirmation (`run_probes.py`, step D, on `w1:p3` with 300 lines of
generated scrollback): `pane.get` before any scroll: `offset_from_bottom: 0,
max_offset_from_bottom: 282`. After the control channel sent
`{"type":"terminal.scroll","direction":"up","lines":40}`: `pane.get` (a
plain, unauthenticated global read -- not from the scrolling client) showed
`offset_from_bottom: 40` immediately. A **separate observe client**
(different `client_id`, opened before the scroll) that had captured a
"bottom of buffer" frame (`scrollline-280..300`) received a fresh frame
*after* the scroll showing older content (`scrollline-244..263` range) with
no scroll command of its own -- proof the mutation is visible to every
reader of the pane, not scoped to the client that issued it. Sending
`{"direction":"down","lines":100}` afterward returned
`offset_from_bottom` to `0` (confirms the mechanism is symmetric and that
cleanup worked). Source and live agree exactly, and both contradict the
study's speculation.

Ruling for 18f (hard requirement, not a suggestion): **do not forward
`terminal.scroll` from the PaneControlChannel FIFO up to herdr.** Any scroll
gesture inside paddock's ghostty surface must stay local to libghostty's own
surface/scrollback (fed by the same `terminal.frame` bytes paddock already
receives) and never become an outbound `terminal.scroll` NDJSON message --
doing so would move the pane's real, shared viewport, which is exactly the
outcome the spec forbids. The FIFO channel itself can stay (other control
message types may still be useful), but `terminal.scroll` is the one message
type this port must not send.

## Q4: non-takeover input forwarding, and concurrent control clients

**Answer: a sole non-takeover control client forwards input normally; two
truly concurrent control/attach clients on the same terminal are
impossible by construction -- ownership is always exclusive, and the only
way to have a second one is to evict the first with `--takeover`.**

Source: same `attach_terminal_client` path as Q1
(`headless.rs:1826-1848`); `ClientInput` for a `TerminalAttach` client calls
`apply_terminal_attach_input` -> `runtime.try_send_bytes`/`try_send_paste`
unconditionally once attached (`headless.rs:2089-2101`,
`pane_input.rs:187-200`) -- there is no additional gate once a client holds
the terminal, takeover or not.

Live confirmation (`step_e_cost.py`): a lone non-takeover control client on
a pane with no prior owner sent `terminal.input` text and it landed exactly
(`pane.read` showed `SOLO_NONTAKEOVER_OK`). Combined with Q1's rejection
evidence, the full state machine is: 0 owners -> attach (takeover irrelevant)
succeeds; 1 owner, non-takeover -> new client rejected, existing untouched;
1 owner, takeover -> existing evicted, new client owns it. There is no
concurrent-write state to design for.

## Q5: per-pane cost of a control child (+ bridge, not yet built)

**Answer: ~8.7 MB RSS steady-state per bare `herdr terminal session control`
child, scaling linearly across 8 panes with no super-linear growth
observed.** This is the herdr-side cost only -- paddock's Swift
`ControlBridge` binary from Task 18f does not exist yet, so the
bridge-process half of the "bridge + control child" pair is **not measured
here** and needs its own measurement once 18f lands.

Live measurement (`step_e_cost.py`, 8 workspaces each with one pane, one
`--takeover` control child per pane, steady state after 2s settle):

| pane | child PID | RSS (KB) |
|---|---|---|
| w1:p1 | 26110 | 8,736 |
| w2:p1 | 26111 | 8,704 |
| w3:p1 | 26113 | 8,704 |
| w4:p1 | 26114 | 8,704 |
| w5:p1 | 26117 | 8,736 |
| w6:p1 | 26118 | 8,704 |
| w7:p1 | 26121 | 8,720 |
| w8:p1 | 26124 | 8,704 |

Sum: 69,712 KB (~68.1 MB) for 8; average 8,714 KB/child. This is the same
order of magnitude as spike 04's observe-child measurements (~9-9.9 MB/pane
at 10-30 panes) -- unsurprising, since it is the same herdr binary doing
comparable framing work either direction. Herdglass's `maxWarmPanes=8` LRU
budget (adopted into paddock's plan) costs roughly **70 MB of herdr-side
child RSS alone** at the cap, before the ghostty surface, the Swift bridge
process, and libghostty's own per-surface memory are added. That combined
number needs a real measurement once 18f's bridge exists (its Step 5 smoke
test is the natural place); this spike only clears the herdr half.

## Surprises for Tasks 17/18f/18h/18i (not part of the 5 questions, but load-bearing)

1. **`herdr terminal session control`/`herdr terminal attach` require
   `<target>` before `--takeover`.** Passing `--takeover` first mis-parses
   the target as an unknown option (confirmed: `unknown terminal session
   control option: w2:p1`). The bridge's argv construction in 18f must put
   flags after the target.
2. **CLI pane-read/write subcommands (`pane get`, `pane run`, direct
   `nc -U` requests) do NOT honor `HERDR_SOCKET_PATH` the way `pane list`
   appears to** -- with the scratch socket exported, `pane run`/`pane get`
   against a pane that unquestionably existed on that exact scratch server
   returned `pane_not_found`, while the identical pane ID resolved fine with
   `HERDR_SOCKET_PATH` unset. Not one of the 5 questions and not chased to a
   root cause (out of scope for this spike), but a real trap for anyone
   scripting probes against a scratch session: **use direct `nc -U
   "$sock"` JSON-RPC for anything that must be scoped to one scratch
   server**, as this spike's scripts do throughout, rather than trusting the
   `herdr pane *` CLI subcommands to respect the env override.
3. **This sandbox has no real controlling tty**, so the brief's suggested
   `script -q /dev/null herdr ...` recipe fails outright (herdr sees a
   zero-sized grid and refuses). `pty_spawn.py`'s explicit
   `ioctl(TIOCSWINSZ)` before exec is the fix; future spikes needing a real
   pty in this environment should reuse that pattern rather than `script`.
4. **herdr refuses nested launches by default** (`HERDR_ENV=1` in the
   environment trips `src/main.rs`'s guard) -- expected, since this whole
   task already runs inside a real herdr pane. Unsetting `HERDR_ENV` only
   for the spawned child (never touching herdr's config) is the correct,
   narrowly-scoped workaround; it does not disable the guard for anything
   else on the machine.

## Cleanup

Every control/observe/attach child, the pty-spawned TUI, and all seeded
workspaces/panes were terminated or killed before finishing; final checks:
`pgrep -f "herdr terminal session control"`, `pgrep -f "herdr terminal
attach"`, `pgrep -f "herdr --session ctl-probe"` all empty except the
scratch server itself, which was then stopped via `scratch-session.sh stop
ctl-probe`; `~/.config/herdr/sessions/paddock-ctl-probe` no longer exists.
