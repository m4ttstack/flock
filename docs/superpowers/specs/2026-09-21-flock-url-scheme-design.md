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

The tray, in the handler it already owns. `POST /pane/focus` gains one branch
in front of what it does today:

- flock is running (checked by bundle id through `NSRunningApplication`):
  `open -g flock://focus?pane=...`, report focused.
- flock is not running: the existing herdr plus ancestry path, unchanged.

Ruled by Matt on 2026-09-21: flock wins when it is running. The ancestry walk
stays on disk because Ghostty is still a real way to use herdr; it simply
stops being the usual route.

The running check is also what keeps the URL scheme from launching flock. A
`flock://` URL opened while flock is closed would otherwise start it, and
starting a terminal multiplexer's GUI because a background notification fired
is not what anyone asked for.

## No reply

The scheme is fire-and-forget. macOS URL handling has no return channel, and
building one would mean a socket or an HTTP listener inside flock.

The cost is one case: flock is running, the pane id is stale, and the tray
reports success anyway. Today's code has the same gap in a different place (a
missed ancestry walk reports a warning nobody reads), and the daemon does
nothing with the outcome except log it.

If a caller ever genuinely needs the answer, that is the moment to add a real
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
| flock running, pane id stale | flock does nothing; the tray reports focused |
| flock running, herdr unreachable | the local selection still happens; the `jumpToHerdr` RPCs fail the way every other flock action does |
| both bundles installed | each owns its own scheme; the tray opens the one that matches the running app |
| a malformed URL | rejected at parse; flock does nothing |

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
  answering the same way.
- **No removal of the ancestry walk.** It is the fallback.
