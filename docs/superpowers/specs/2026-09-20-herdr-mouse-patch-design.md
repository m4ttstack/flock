# Installing herdr's mouse patch from flock

## Why this exists

flock renders every pane with libghostty and owns the surface the pointer is
over, but it cannot hand a click to the program running in that pane. Two
things are missing from `herdr terminal session control`, the documented CLI
surface flock is built on:

- a way to send a mouse event in, and
- a way to learn that the pane's program turned mouse reporting on.

herdr's own client gets both halves from the server. The CLI does not expose
them. So a picker, a TUI, or a right-click menu inside a pane is unreachable
through the documented path, and that is the one capability gap between flock
and the terminal it replaces.

The change itself is small and already written: one commit, `a83af1c8` on the
local `paddock-mouse-control-cli` branch, 266 insertions across 5 files, with 5
tests. It adds `terminal.mouse` inbound and `terminal.mouse_capture` outbound.
It was offered upstream in discussion 4058 on 2026-09-13 and has no maintainer
reply.

**This spec assumes upstream never answers.** herdr's `CONTRIBUTING.md` closes
unsolicited pull requests and its approved-contributor list is curated, so the
discussion is the only channel and it is not a plan. If the change is adopted
later, this feature detects a herdr that already has the verbs and says so.

## The three facts this design rests on

1. **herdr is Apache-2.0.** A patched build may be made and redistributed,
   provided the license and NOTICE travel with it and the changes are stated.
   No permission is required and none should be implied.

2. **The patch is client-side only.** `a83af1c8` touches `src/client/*` and the
   docs, and nothing else. This was verified live on 2026-09-18: a patched
   client drove an untouched 0.9.1 server, mouse reports reached the program,
   and the server was never restarted. That single fact is what makes this
   feature reasonable rather than reckless, because flock never has to stop the
   user's herdr, touch their daemon, or interrupt a running session.

3. **A plugin cannot do this.** herdr spawns plugins as external processes
   (`src/plugin_command.rs`) that talk the same public API flock uses, so a
   plugin has no more reach into pane state than flock has. The state needed
   lives in `TerminalDirtyPatchSnapshot` (`src/pane.rs`), which is
   `pub(crate)`. Patching the binary is the only route that works.

## What the user sees

One row in flock's settings, under a heading about herdr rather than about
flock. It has four possible states and says which one is true:

| State | What the row says | Action |
| --- | --- | --- |
| herdr already supports mouse | mouse support is present, nothing to do | none |
| patchable | the installed herdr can be patched, and what that means | Install |
| patched by flock | installed, with the version it was built against | Revert |
| not patchable | this herdr version is not covered, and why | none |

The copy never says "upgrade herdr" or implies the maintainers endorsed this.
It states plainly that flock will replace the herdr binary with a build of the
same version carrying an extra CLI verb, that a backup is kept, and that it can
be undone.

**Installing asks first, every time.** This modifies a tool flock does not own,
on the user's machine. A single confirmation naming the exact path being
replaced is the minimum, and it is never remembered as a preference.

## How it works

### Finding herdr

The same resolver flock already uses. `ToolPath` resolves `herdr` on the
resolved PATH today, and `GhosttyControlSurfaceFactory` logs when it cannot.
This feature reads that answer rather than searching on its own.

Where it lands matters for permissions. A herdr in `~/.local/bin` is the
user's own file. A herdr under `/opt/homebrew` or `/usr/local` may not be
writable, and Homebrew will overwrite it on the next upgrade regardless. When
the install location is not writable by the user, the row says so and offers
nothing: prompting for an admin password to modify another project's binary is
a line this feature does not cross.

### Deciding whether it is already patched

Read the binary, do not run it. Running an unknown herdr build to interrogate
it is both slower and riskier than inspecting it. The marker is the presence of
the verb's own strings in the binary, the same check used by hand on
2026-09-18 to prove an installed plugin lacked a shipped surface.

Detection answers three separate questions, and they must not be collapsed:

- does this binary already carry `terminal.mouse`, whether from flock or from
  upstream having adopted it,
- what herdr version is it,
- is there a flock backup beside it.

A binary that carries the verbs without a flock backup is upstream adoption,
and the row should celebrate that rather than offer to patch.

### Shipping the patched binary

flock carries prebuilt patched binaries, one per supported herdr version and
architecture, rather than building on the user's machine. Building would mean
fetching herdr's source, downloading the Zig version named by its
`build.zig.zon`, and a multi-minute compile on first use. That is a bad first
run for a feature that should take a second.

The cost is a build matrix and staleness: a herdr version flock does not carry
gets the "not patchable" state. That is the correct failure. **Never install a
binary built against a different herdr version than the one present**, because
a client and server that disagree about the protocol fail in ways the user
will blame on flock.

Each shipped binary records the herdr version it was built from, the upstream
commit, and the patch commit, and that provenance is what the settings row
reads back to the user.

### Installing

The sequence proved by hand on 2026-09-18, and the reason for each step:

1. Copy the existing herdr beside itself as `herdr.pre-flock-mouse-backup`.
   A backup the user can find and restore by hand, without flock.
2. Write the new binary to a temporary name in the same directory, so the
   rename is atomic and cannot leave a half-written file where herdr was.
3. `mv -f` it into place. **Rename, never overwrite in place**: a running
   process keeps its open image, so an in-flight herdr is undisturbed and
   in-flight panes keep working.
4. Verify the installed file carries the verbs, and report what happened.

No daemon is stopped or started. No session is touched. The next herdr the
user invokes is the patched one.

### Reverting

Restore the backup by the same rename, verify the verbs are gone, and remove
the backup only after the restore is verified. Revert must work even when
flock no longer carries a matching prebuilt binary, because it is a file move
and needs nothing else.

### Surviving a herdr upgrade

A herdr upgrade replaces the binary and the patch disappears. This is expected
and must not be treated as an error. flock re-checks on launch, notices the
verbs are gone, and the row returns to "patchable" for the new version if one
is carried, or "not patchable" if not. The stale backup is cleaned up once it
no longer matches anything, so it cannot be restored over a newer herdr.

**flock never re-patches silently.** A binary that changed underneath is a
binary the user changed, and re-applying without asking would make flock a
thing that quietly modifies other software.

## What this does not do

- **No building from source on the user's machine.** Prebuilt or nothing.
- **No admin escalation.** A herdr the user cannot write is left alone.
- **No automatic patching**, at install or at launch. Always an explicit action.
- **No bundling of herdr itself.** flock patches the herdr that is there; it
  does not become a way to install herdr.
- **No mouse behaviour.** This spec covers getting the verbs onto the machine.
  What flock does with them once present is the existing mouse work, already
  built against the patched CLI.

## Degrading

| Missing | What flock does |
| --- | --- |
| no herdr at all | the row is absent; the no-herdr screen owns that case |
| herdr not writable | the row explains, and offers nothing |
| no prebuilt for this version | the row says which version is installed and that it is not covered |
| already patched upstream | the row says mouse support is present, with no action |
| backup missing at revert | the row says revert is unavailable and why, rather than failing mid-move |

## Testing

The decisions are pure and belong in `FlockCore` with tests over fixtures:
which state the row is in, given a version, a verb-presence answer, a
writability answer and a backup answer. That matrix is the feature.

The file moves are the impure part and are tested against a temporary
directory tree, never against a real herdr. **No test may run `herdr`**, and
no test may touch a real install: this is the developer's own machine with a
live server and real agent panes, and that rule has held all the way through
this project.

What cannot be tested automatically, and must be checked by hand: that a
patched client actually drives an untouched running server. That was verified
once, on 2026-09-18, and should be re-verified whenever a new prebuilt binary
is added for a new herdr version.

## The open question

How many herdr versions flock carries, and what happens when the user's
version is newer than all of them. The honest answer today is that it says so
and does nothing, which is correct but unsatisfying if herdr releases often.
Worth revisiting once there is evidence about how fast that happens; not worth
designing for now.
