# Spike 02: NDJSON socket client framing

Probe executable: `spikes/02-socket/Sources/main.swift` (SPM executable
`PaddockSocketSpike`). Run against real scratch herdr sessions started with
`spikes/lib/scratch-session.sh`, never the default `~/.config/herdr/herdr.sock`.

```
swift build   # in spikes/02-socket
sock=$(spikes/lib/scratch-session.sh start <name>)
.build/debug/PaddockSocketSpike probeA "$sock"
.build/debug/PaddockSocketSpike probeB "$sock" "$(pwd)/spikes/lib/seed-layout.sh"
spikes/lib/scratch-session.sh stop <name>
```

## Headline finding: herdr's api socket is one-request-per-connection

The task brief and the design doc's "docs say yes" note assume a single
connection can carry multiple concurrent requests. Direct testing against a
real herdr 0.8.0 scratch server (both from this probe and from independent
raw-socket exploration in Python, to rule out a Swift/DispatchIO artifact)
shows the opposite: **every connection to `herdr.sock` is answered exactly
once, then the server closes it.** A second request written to an
already-answered connection gets `EPIPE` (errno 32); nothing ever answers it.

Evidence, two back-to-back `ping`s on one connection (Python, for an
implementation-independent check):

```
0 OK {'id': 'ping-0', 'result': {...}}
1 FAIL [Errno 32] Broken pipe
```

`lsof` on the server while this happens shows the api socket
(`herdr.sock`) and a second, separate `herdr-client.sock` (the server log
calls it "client protocol socket" -- used by the interactive `herdr` TUI
client, not the JSON api this spike targets). Nothing about the JSON api
surface documents or implies a keep-alive socket; the design doc's own
bootstrap sequence already uses two separate connections (one for
`events.subscribe`, one for `session.snapshot`), which is consistent with
this finding, not contradicted by it.

`events.subscribe` is the one documented exception, and it is narrower than
"multiple requests share a connection": the subscribe connection stays open
so the server can push events, but it does **not** accept a second request.
Sending anything else on it (a `ping`, in this probe) makes the server tear
the whole connection down -- the subscription itself is lost, not just the
extra request:

```
[NOTE] second request on a subscribe connection: connection closed = true
(errno 0), total lines ever received = 1 (expected 1, the ack only; sending
anything else on a subscribe connection tears it down)
```

**Consequence for Task 11:** the real client cannot hold one connection open
for request/response traffic. Every request needs its own short-lived
connection (verified pattern below), and the `events.subscribe` connection
must be used for nothing but that one subscribe call plus the incoming event
stream -- never interleaved with any other request, ever.

## Probe A: request/response correctness

`spikes/02-socket/Sources/main.swift` `runProbeA`. Two parts:

**Part 1, as literally specified in the brief** (ping + session.snapshot +
1000x `pane.get`, all with distinct ids, on one connection): **FAIL**, exactly
per the headline finding above. Precise evidence from a real run:

```
[PASS] ping answered on the shared connection (request #1)
[FAIL] single shared connection answers ping + session.snapshot + 1000x
       pane.get, all with distinct ids (as literally specified)
[NOTE] single-connection evidence: request #1 (ping) answered = true;
       request #2 (session.snapshot) got a response = false (write
       errno=32); of 1000 queued pane.get writes, 0 completed without a
       local write error and 1000 failed locally; total response lines
       ever seen on this connection = 1 (expected 1002 if multiplexing
       worked); onClose fired with errno 0
```

(A separate exploratory run that queued writes before checking for errors,
outside this probe, got 88 of 1000 sends accepted into the local socket
buffer before the peer's close was noticed as `EPIPE` -- the OS write buffer
absorbs some writes before the broken connection surfaces locally. Only the
very first request's response was ever read either way.)

**Part 2, the pattern Task 11 must actually use** (one connection per
request, bounded concurrency 32): **PASS**, and this is what the brief's
acceptance criteria are verified against.

```
[PASS] ping answered
[PASS] multibyte label (box-drawing/CJK/emoji) round-trips intact through session.snapshot
[PASS] session.snapshot answered
[PASS] every one-shot connection produced a result object (missing: 0)
[PASS] every response parsed as JSON (parse failures: 0)
[PASS] every response id matched the request id it was sent for (mismatches: 0)
[PASS] every pane.get response named the correct pane_id (wrong: 0)
Probe A part 2: 1000 one-shot requests, concurrency 32, 1932ms total, 1.932ms/req avg
```

1000/1000 distinct ids answered exactly once, JSON parsed cleanly every time,
no interleaving corruption, and the multibyte label
(`spike├──┐ 界 café naïve 🚀` -- box-drawing, CJK, accented Latin, emoji)
round-tripped byte-for-byte through `workspace.create` -> `session.snapshot`.
Wall time varied 1.3s-1.9s across runs (~1.3-1.9ms/request at concurrency 32
against a scratch server with nothing else running).

## Probe B: subscription stream + cancellation

`runProbeB`. Subscribes to `layout.updated` + `pane.updated` on one
long-lived connection, drives two `seed-layout.sh` runs plus 150 alternating
right/down `pane.split` calls on a separate one-shot connection per request,
then closes the subscriber connection abruptly mid-stream.

**Ordered delivery under a burst:** PASS. All received lines are valid JSON
carrying an `event` or `id` field, and per-line receive timestamps
(monotonic, taken as `LineSocket` drains each line off the buffer) are
non-decreasing across a full run -- no reordering introduced by DispatchIO's
buffering.

**>64KB line, unfragmented:** the brief's suggested 12 splits does not come
close (measured: a 15-pane snapshot was 7462 bytes; a single `layout.updated`
for one tab is smaller still, since it carries only that tab's pane/split
tree). Measured growth curve (split count -> max `layout.updated` bytes seen
so far, one representative run):

| splits | max event bytes | splits | max event bytes |
|---|---|---|---|
| 10 | 474 | 90 | 8284 |
| 20 | 1725 | 100 | 10044 |
| 30 | 2089 | 110 | 11176 |
| 40 | 3402 | 120 | 12804 |
| 50 | 4566 | 130 | 14968 |
| 60 | 4962 | 140 | 16708 |
| 70 | 6796 | 150 | 18238 |
| 80 | 8068 |  |  |

Even at 150 splits (one tab, one long BSP split chain) the single-tab
`layout.updated` event tops out around 18-20KB, well under 64KB -- a single
tab's layout tree just doesn't grow fast enough per split to get there in a
reasonable number of real panes. Per the brief's fallback clause, the probe
falls back to `session.snapshot` (which serializes every workspace/tab/pane,
not just one tab) to exercise the >64KB-unfragmented path: at 150 splits plus
the two seed-layout workspaces, `session.snapshot` is **85128 bytes** and
still arrives as one clean NDJSON line, parsed correctly with no truncation.
**PASS via the fallback**, as the brief anticipates; the as-specified
12-split target does not reach 64KB on this protocol version and larger
split counts (150) still don't get the *per-event* line there, only the
full-snapshot response.

**Close mid-stream:** PASS. `closeAbruptly()` triggers `channel.close(flags:
.stop)`; the read callback observes `done=true` (errno 89 on some runs, 0 on
others depending on whether the server had already half-closed) with no
crash. `lsof -p <pid> | grep '<fd>u'` after close finds no match in every
run -- the fd is not leaked.

**Event propagation latency vs. the 100ms server poll:** measured by timing
from "one-shot `pane.split` response received" to "subscriber observed a new
event line," sampled every 20 splits. Representative samples across two runs:
`16.8, 32.4, 61.8, 83.1, 94.4, 95.7, 104.7, 105.9, 110.0, 112.2, 114.0,
115.1, 118.3` ms. This lines up with the design doc's documented 100ms
server-side event poll: most samples cluster just under or around 100ms,
with a few faster ones (the poll firing shortly after the mutation landed) --
consistent with a single fixed-interval poll rather than push-on-mutation.

## Deviations from the brief's skeleton

- **Per-connection queue, not `.main`.** The skeleton drives `DispatchIO` on
  `.main` and issues `send` without ever blocking. A synchronous probe needs
  its main thread to block on the response, which would deadlock if the
  channel itself also ran on `.main` (the read callback could never run).
  Each `LineSocket` gets its own private serial `DispatchQueue` instead.
- **`SO_NOSIGPIPE` + `signal(SIGPIPE, SIG_IGN)`.** Not in the skeleton, and
  not optional: writing to a connection the peer has already closed raises
  `SIGPIPE` on Darwin by default, which kills the process outright rather
  than surfacing as an error. This is exactly the failure mode Probe A's
  Part 1 deliberately provokes (writing 1000 requests to a connection that
  died after the first response), so without this hardening the probe would
  crash instead of reporting `EPIPE` as data. **Task 11 needs this too** --
  any request fired at a connection that the one-shot server has already
  closed will hit this otherwise.
- **One connection per request, not one shared connection.** Direct
  consequence of the headline finding; see "Verified pattern" in Probe A and
  `oneShotRequest`/`runConcurrentOneShots` in `main.swift`.
- **`sockaddr_un` path copy uses `withUnsafeBytes` on the byte array** rather
  than constructing a standalone `UnsafeRawBufferPointer(start:count:)` from
  it (the skeleton's approach compiles but the compiler correctly flags it as
  a dangling-pointer risk under Swift 6 -- the buffer pointer must not outlive
  the `withUnsafeBytes` call that produces it).
- **Package pinned to Swift language mode v5** (`Package.swift`
  `swiftSettings: [.swiftLanguageMode(.v5)]`). The probe's synchronous
  request/response harness intentionally shares mutable state
  (`NSLock`-guarded dictionaries/arrays) across GCD queues in a way the
  Swift 6 strict concurrency checker cannot verify and that would need a
  real actor-based redesign to satisfy -- reasonable for throwaway probe
  code, but Task 11's real client should design its concurrency model
  actor-first from the start rather than opting out of checking.

## Summary for Task 11

- Do **not** pool or reuse connections for request/response traffic; open one
  connection per request (or a small worker pool of one-shot connections, as
  this probe does at concurrency 32 with no failures at 1000 requests).
- The `events.subscribe` connection is single-purpose: subscribe once, then
  only read from it. Never write anything else to it -- doing so kills the
  subscription, not just the extra write.
- `SO_NOSIGPIPE` on every socket fd (and/or a process-wide `SIG_IGN` on
  `SIGPIPE`) is required, not optional, given the one-shot-connection
  protocol: any request that outlives its connection's server-side close
  will otherwise crash the process instead of returning an error.
- Bootstrap re-snapshot (`session.snapshot`) is the only response type
  observed to reliably cross 64KB in ordinary use; individual
  `layout.updated` events stay well under that even under a deliberately
  large single-tab split tree. A real client's line-framing buffer should
  not assume events are small, but the large-line risk is dominated by
  `session.snapshot`, not by per-event traffic.
- Observed event latency clusters close to the documented 100ms server poll
  interval, with no observed reordering or corruption across bursts.
