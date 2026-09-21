# Asking flock to focus a pane

> **NOT BUILT, and deliberately so.** This was designed, reviewed to approval,
> implemented across two repos, and then cut back to about five lines in
> rt-tray. Kept so nobody rebuilds it without knowing why it was dropped. The
> reasoning is at the bottom, under "Why this was cut".

## The problem it addressed

An outside program that knows a herdr pane id should be able to put the user
in front of that pane. rt uses this constantly: the daemon's `pane:focus`
verb, a tray notification click, a gate that needs an answer.

That request travels a long way and ends in a guess:

```
rt daemon (pane:focus)
  -> POST /pane/focus  (rt-tray's local HTTP server)
    -> herdr workspace focus / tab focus   (socket, exact)
    -> walk the process tree from the pane's shell to a terminal app
    -> NSRunningApplication.activate()
```

`HerdrBridge.swift` says why the walk exists: "herdr's socket API exposes no
way to learn which OS process/window hosts a pane, so ancestry is the only way
to find something activatable."

## What was designed

A URL scheme flock registers, one verb wide:

```
flock://focus?pane=<pane-id>
```

flock would resolve the pane's tab and workspace from the model it already
mirrors, focus all three through the `jumpToHerdr` calls that already exist,
and activate its own window. The tray would check whether flock was running
and open that URL at it, falling back to the ancestry walk otherwise.

## Why this was cut

**The two halves of "focus a pane" are not equally hard, and only one of them
was ever broken.**

Selecting the pane already worked, with no flock code at all. The tray sends
`workspace focus` and `tab focus` to herdr over the socket, herdr moves its
focus, and flock mirrors herdr. Observed live on 2026-09-21: clicking a focus
element in mattstack chat moved flock to the right pane, with none of this
feature installed.

What did not work was raising flock's window, and the reason is mundane:
`TerminalResolver.terminalBundleMarkers` is a hardcoded list of terminal
emulators (Ghostty, iTerm, Terminal, WezTerm, kitty, Alacritty, Warp) and
flock is not on it. So the walk found nothing activatable and gave up.

Raising a window is the one thing that genuinely cannot be deferred to herdr,
because which OS window shows a pane is a client fact and herdr has no channel
for it. But the fix for it is a preference check in the tray, not an inbound
control surface on flock: if flock is running, activate it; otherwise walk the
ancestry as before.

The URL scheme's only remaining advantage was that flock would select the
workspace, tab and pane itself rather than waiting for herdr's echo. The echo
demonstrably already works, so that bought nothing observable, at the cost of
a URL surface any process or web page on the machine can knock on.

Ruled by Matt on 2026-09-21: cut it back. flock's whole philosophy is to defer
to herdr and mirror the result, and a feature that adds a second control plane
for something herdr already answers is working against that.

## What shipped instead

One change in rt-tray, inside `HerdrBridge.focusPane(_:)`, which all four
focus paths funnel through: a running flock is activated directly and the
ancestry walk is skipped. Nothing in flock changed.

## What is still true and worth keeping

- **If a future feature needs flock to do something herdr cannot express**,
  this document is the design for the door, including the rule that such a
  scheme carries only non-destructive, user-visible verbs, and the two-bundle
  problem (`dev.mattstack.Flock` and `dev.mattstack.Flock.dev` would both
  register the same scheme, so the dev bundle needs its own).
- **The tray answers "does this pane exist" from herdr's own `pane list`**,
  before anything else runs. `lib/daemon/handlers/pane.ts:399` fails the
  command on `ok: false`, and `rt pane focus` surfaces it, so a stale pane id
  is a CLI error. Any change here must keep that lookup in front.
