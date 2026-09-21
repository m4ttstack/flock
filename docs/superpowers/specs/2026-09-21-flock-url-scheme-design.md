# Asking flock to focus a pane

## Why this exists

An outside program that knows a herdr pane id should be able to put the user
in front of that pane. rt uses this constantly: the daemon's `pane:focus`
verb, a tray notification click, a gate that needs an answer.

Today that request travels a long way and ends in a guess:

```
rt daemon (pane:focus)
  -> POST /pane/focus  (rt-tray's local HTTP server)
    -> herdr workspace focus / tab focus   (socket, exact)
    -> walk the process tree from the pane's shell to a terminal app
    -> NSRunningApplication.activate()
```

The last two steps are the problem, and `HerdrBridge.swift` says why in its
own comment: "herdr's socket API exposes no way to learn which OS
process/window hosts a pane, so ancestry is the only way to find something
activatable." When the walk misses, there is a second fallback that looks for
any herdr attach client, and when that misses too the tray logs a warning and
the user is simply left where they were.

flock does not have this problem. It is the app, it holds the window, and it
already mirrors which pane is in which tab in which workspace. Asking flock to
focus a pane needs no inference at all.

flock has no inbound surface today: no URL scheme, no socket, no listener.
This adds the first one.

## What is built

A URL scheme flock registers, one verb wide:

```
flock://focus?pane=<pane-id>
```

Query form rather than a path so later verbs can add parameters without
changing the shape. `<pane-id>` is percent-encoded, since herdr pane ids
contain a colon (`w1:p2`).

### What flock does with it

1. Resolve the pane's tab and workspace from the model flock already mirrors.
2. `jumpToHerdr(workspace:)`, then `jumpToHerdr(tab:)`, then
   `jumpToHerdr(pane:)`, which already exist and each do the local selection
   plus the matching herdr RPC.
3. Activate flock's own window.

Step 2 matters beyond flock's own view: those calls send real
`workspace.focus` / `tab.focus` / `pane.focus` requests, so herdr's session
focus follows. That is what the tray was already doing through the socket, and
dropping it would leave herdr's idea of the focused pane behind flock's.

**An unknown pane id does nothing, silently.** flock mirrors herdr, so a pane
herdr has is a pane flock has; an id that resolves to nothing is a stale id
from a pane that has since closed. There is no user standing in front of flock
waiting for an answer, so an error surface here would interrupt them about
something they did not do.

### Who decides between flock and Ghostty

The tray, inside `HerdrBridge.focusPane(_:)`, which is the one function every
focus path already funnels through. Putting the branch there rather than in
the daemon's HTTP handler is what makes it reach all four callers:
`TrayServer`'s `POST /pane/focus`, both of `NotificationManager`'s click
handlers, and `ProcessPanelController`. Notification clicks are half the
reason this feature exists, so branching only the daemon route would have
left the guessing in place for the case most worth fixing.

The branch itself:

- flock is running (checked by bundle id through `NSRunningApplication`):
  open the focus URL at it and return. The tray sends no `workspace focus` or
  `tab focus` of its own, because flock's handler sends all three itself.
- flock is not running: the existing herdr plus ancestry path, unchanged.

Ruled by Matt on 2026-09-21: flock wins when it is running. The ancestry walk
stays on disk because Ghostty is still a real way to use herdr; it simply
stops being the usual route.

The running check is also what keeps the URL scheme from launching flock. A
`flock://` URL opened while flock is closed would otherwise start it, and
starting a terminal multiplexer's GUI because a background notification fired
is not what anyone asked for.

## No reply, and why that costs nothing here

The scheme is fire-and-forget. macOS URL handling has no return channel, and
building one would mean a socket or an HTTP listener inside flock.

**The outcome still matters, so the tray answers it without flock's help.**
`lib/daemon/handlers/pane.ts:399` fails the command on a non-2xx or an
`ok: false` body, and `rt pane focus` surfaces that, so an unknown pane id is
a CLI error today. Reporting a blind success would quietly turn that into
exit 0, and the caller would have no way to tell a focused pane from a pane
that closed an hour ago.

`focusPaneById` already resolves the pane through herdr's own `pane list`
before doing anything, and that lookup is what keeps answering. A pane herdr
does not have is still a 404, exactly as now; only once the pane is known does
the flock branch run. flock mirrors herdr, so herdr having the pane is a sound
proxy for flock having it.

That leaves one genuinely unanswerable case: herdr has the pane, flock is
running, and flock still fails to focus it. That would be a flock bug rather
than a stale request, and a reply channel is the wrong place to discover it.

**The proxy holds only while both talk to the same herdr session.** The tray
shells out to `herdr`, which uses the default socket; flock takes
`HERDR_SOCKET_PATH` when it is set, which is how it is pointed at a scratch
session during testing. A flock launched that way mirrors panes the tray's
herdr has never heard of, and vice versa, so the tray would 404 a pane flock
is showing. Normal use has one session on the default socket and the question
does not arise. This is not worth code: a focus request aimed at a test
session is a test artefact, and making the tray chase flock's socket would
mean flock answering a question it has no channel to answer.

If a caller ever needs more than this, that is the moment to add a real
transport, not before.

## Security posture

Registering a scheme opens a door that any process, and any web page the user
clicks, can knock on. That is acceptable for this verb and is the reason to
write the rule down while the door is one verb wide:

**This scheme carries only non-destructive, user-visible verbs.** Focusing,
selecting, revealing. Never input injection, never anything that runs a
command, never anything that changes a pane's contents or the session's
layout. A request that would be dangerous coming from an arbitrary web page
does not belong here, whatever it would save.

The natural next asks (send text to a pane, launch a harness) are exactly the
ones this rule refuses. They need a transport that can establish who is
calling.

## The two-bundle wrinkle

flock ships as two bundles: `dev.mattstack.Flock` and
`dev.mattstack.Flock.dev`. Both would register the same scheme, and macOS
picks one handler for a scheme, with no guarantee it is the copy that is
running.

The dev bundle registers `flock-dev://` instead. The tray checks which flock
is running and opens the matching scheme, preferring the prod bundle when both
somehow are.

## Degrading

| Situation | What happens |
| --- | --- |
| flock not running | the tray takes the existing herdr plus ancestry path |
| pane id stale (herdr does not have it) | 404 from the tray, `rt pane focus` errors, unchanged from today. The flock branch never runs, because the herdr lookup fails first |
| herdr unreachable | 500 from the tray, unchanged from today |
| herdr has the pane, flock running, flock fails to focus it | the tray reports focused anyway. The one case no caller can see, and a flock bug rather than a stale request |
| flock running, herdr reachable, but flock's own RPCs fail | flock's local selection still happens; the `jumpToHerdr` calls fail the way every other flock action does |
| both bundles installed | each owns its own scheme; the tray opens the one matching the running app, preferring prod |
| a malformed URL | rejected at parse; flock does nothing |
| a notification click or the process panel | same branch, because it lives in `focusPane(_:)` rather than in the HTTP handler |
| flock pointed at a different herdr session (`HERDR_SOCKET_PATH`) | the tray answers from its own herdr, so a pane only flock has is a 404. A test-harness situation, not a real one |

## Testing

The parse (`flock://focus?pane=...` to a `PaneID`, and every malformed form
rejected) and the resolution (a pane id to its tab and workspace, given a
model) are pure, and belong in `FlockCore` with unit tests. That is the part
worth testing and it is most of the logic.

Activation and the tray's running check need a real machine and real windows,
and get checked by hand. This is consistent with the rest of flock: a surface
with a live child pegs the main thread in its own render loop, so tests here
cannot drive a running app.

## What this does not do

- **No other verbs.** Focus only, even though the shape allows more.
- **No reply channel.**
- **No launching flock.** The tray checks first.
- **No change to the daemon.** It keeps calling the tray; the tray keeps
  answering the same way, with the same status codes for the same reasons.
- **No removal of the ancestry walk.** It is the fallback.
