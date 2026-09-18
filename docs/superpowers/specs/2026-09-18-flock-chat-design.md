# Chat in flock

**Goal:** every feature of the `m4ttstack.chat` herdr plugin works inside flock,
shaped as a Mac app rather than as a terminal popup, and without needing a
prefix key.

**Status:** design approved 2026-09-18. Spans two repos.

## Why

flock is first and foremost a native, drag-capable surface for herdr. It is not
a mattstack client. But when mattstack is on the machine, flock should use it,
and the first place that pays off is chat: the plugin already puts `rt chat`
where the agents live, and today none of it reaches flock.

In herdr the features need a prefix key because a terminal has nothing else. In
flock they can be buttons, and a pane can wear its own chat state.

## What exists today

`~/Documents/GitHub/herdr-chat` is a Rust binary installed as a herdr plugin. It
has seven actions, each a subcommand that draws a ratatui TUI:

| Action | What it does |
| --- | --- |
| `launcher` | one popup listing the other six, each behind a letter |
| `broadcast` | one message into a selection of panes |
| `peek` | who is online, what is unread |
| `quick-send` | a line at a room or DM |
| `sign-in` / `sign-out` | put a pane on or off the chat buddy list |
| `open-viewer` | hand off to the web viewer for reading |

Its layers are already close to what this needs. `rt.rs` (627 lines) is typed
wrappers over `rt ... --json`; `herdr.rs` (449) talks to herdr; `state.rs` and
`deck.rs` carry the rest. The seven flows in `src/cmd/` (~2,500 lines) are where
decisions and TUI drawing are mixed together. `ui.rs` and `theme.rs` are pure
rendering.

**flock cannot render those TUIs, and that is settled rather than assumed.** A
herdr popup travels to a client as `popup_cells` inside `ServerMessage::PaneSurface`,
produced only on the `ClientShell` branch; flock's bridge negotiates
`TerminalAttach`. herdr's own test `plugin_pane_open_popup_is_layout_neutral`
asserts an api-opened popup is absent from `pane.list`, absent from
`plugin_panes`, and emits no api event. Invoking a popup action from flock today
would open an invisible popup that steals keystrokes from the terminal TUI if
one is attached.

## Architecture

Three layers, one binary.

```
rt chat / rt pane / deck          (unchanged)
        |
herdr-chat headless verbs         (new: --json, no TUI, inputs as flags)
        |
   +----+----+
   |         |
herdr TUI   flock native UI       (unchanged / new)
```

The headless layer is the whole of the split. Neither front end gets to own a
decision the other needs.

### The headless surface

Every existing subcommand accepts `--json`. With it, the subcommand **never
draws**, takes its inputs as flags, and prints exactly one JSON object on
stdout. Without it, today's behaviour is unchanged, so the herdr TUI keeps
working as it does now.

`--json` with a missing required flag is an error, never a prompt and never a
fallback to the TUI. Mode is chosen by the caller, not inferred from a TTY.

| Verb | Inputs | Output |
| --- | --- | --- |
| `status --json` | `--pane <id>` | `{ handle, state, pane, signedIn, rooms[] }` |
| `peek --json` | | `{ buddies: [{handle, paneId, status, repo, branch, title, unread, mentions}], rooms: [{room, unread, mentions}] }` |
| `targets --json` | | `{ rooms: [#name], people: [@handle] }` |
| `quick-send --json` | `--to <#room\|@handle> --body <text>` | `{ ok, to }` |
| `broadcast --json` | `--panes <id,...> --body <text>` | `{ ok, results: [{paneId, ok, delivered, error?}] }` |
| `sign-in --json` | `--pane <id>` | the same object as `status` |
| `sign-out --json` | `--pane <id>` | the same object as `status` |
| `jump --json` | `--handle <h>` | `{ paneId, workspace, handle }` |
| `open-viewer --json` | `--room <name>` optional | `{ url }` |

Four of those shapes carry a reason.

**`peek` and `jump` answer with a `paneId` and no workspace or tab id.** rt's
pane roster has neither: a pane row carries `paneId` and a workspace *name*, and
nothing about tabs. herdr's own snapshot does have the ids, but reaching for
them would mean this binary calling herdr to compute something flock already
holds... flock renders the whole layout, so it maps a pane id to its workspace
and tab from the model in memory, with no call at all.

**The sign verbs answer with the full status object rather than a bare
handle.** rt's own reply is `{ok, handle, room}` for sign-in and `{ok}` for
sign-out, which does not say what the header should now read. The caller's next
question after signing is always "what does the header say now", so the verb
answers it in the same call instead of leaving a second round trip and a race.

**`broadcast` carries rt's own `delivered` word beside `ok`.** rt answers a
send with `accepted`, `queued`, or `refused`; only `refused` is a failure, and a
caller that wants to tell a queued send from an accepted one needs the word rt
used.

**`targets` returns prefixed names.** `#room` and `@handle` are one namespace
the caller passes straight back as `--to`, where a bare name would be ambiguous
between a room and a person.

Two verbs deserve their reasoning stated. `jump` returns ids rather than moving
focus, because flock focuses panes itself and moving focus twice fights its own
model. `open-viewer --json` returns the URL rather than shelling out to `open`,
for the same reason: flock decides how a URL is opened, and a test can assert a
URL where it cannot assert that `open` ran.

`broadcast` reports per pane. A broadcast where two of three panes took the
message is not a failure, and the caller has to be able to say so.

### What the TUI front end changes

Only its plumbing. Each `src/cmd/*.rs` keeps its screens and moves its decisions
into a headless function the `--json` path also calls. Behaviour visible to a
herdr user does not change, and that is the acceptance bar for this half.

### How flock reaches the binary

Resolution order, first hit wins:

1. `FLOCK_HERDR_CHAT_BIN` if set.
2. `~/.config/herdr/plugins/*/m4ttstack.chat*/target/release/herdr-chat`, newest
   mtime if several match.
3. Absent.

**Unverified:** that herdr guarantees the `<source>/<id>[-hash]` directory shape
the glob assumes. Two installs exist on this machine (`config/m4ttstack.chat`
and `github/m4ttstack.chat-3fdefc4d82ce`), which is evidence, not a contract.
Confirm against herdr's plugin installer before relying on it.

## Degrading when mattstack is not there

flock is a herdr client that knows about mattstack **where it helps**. On a
machine without mattstack it must be a flock with no chat in it, not a flock
with broken chat in it. Every layer below can be missing independently, so each
gets its own answer rather than one blanket try/catch.

| Missing | What flock does |
| --- | --- |
| `herdr-chat` binary | No chat button on any pane, no Chat menu. Nothing greyed out, no dialogue, no explanation. |
| `rt` binary | Same as above: chat is absent, not broken. Detected once, with the binary probe. |
| `rt` daemon not running | Chat UI is present (the machine has mattstack) but every verb fails. The popover opens and says so in one line, with a Retry. It does not try to start the daemon. |
| `deck` | Open viewer alone is disabled, with its own reason on hover. Everything else works. The plugin's own README already treats deck as optional. |
| Signed out of chat | Not a failure. Sign in is the primary button, and send actions are disabled with the footer naming why. |

Four rules bind the implementation:

- **Probe once per launch, cache the answer, never on the main actor.** A
  missing binary must cost nothing on every render, and a slow filesystem must
  never stall a frame. The last cold-pane investigation found a login-shell
  `PATH` probe blocking the main actor for up to 334ms; do not reintroduce that
  shape here.
- **Every verb call has a deadline.** A hung `rt` daemon fails the call and
  raises the toast; it never leaves a spinner up forever and never blocks
  quitting the app.
- **Absence is decided by the resolver, not by catching an error.** Code that
  reaches a chat verb has already established the binary exists. A failure from
  there on is a real failure worth reporting, which is what keeps the "nothing
  explains what is missing" rule from swallowing genuine breakage.
- **Absence is re-checked when the user asks, not polled.** Installing mattstack
  while flock runs does not light chat up mid-session; the next launch does.
  Polling for an absent dependency is work on every machine that will never have
  it.

A test drives each row of that table, including the one where everything is
present, so "chat is absent" and "chat is broken" can never collapse into each
other.

## flock's surfaces

Designs: `docs/design/chat/` (`flock-chat.pen` is the source).

### Trigger and placement

`trigger-and-placement.png`

A chat button sits in each pane's top chrome, left of the agent status dot. It
is both the trigger and the state:

- **Signed in:** the pane's chat handle, a divider, the chat glyph, and the
  unread count. Accent-bordered.
- **Signed out:** the chat glyph alone, muted, no border.
- **No chat binary:** no button.

Clicking it opens the chat popover, anchored under the button and right-aligned
to it. The popover belongs to that pane and closes on click-away or Esc.

Three ways to the same thing: the button, a Chat menu in the menu bar, and the
user's existing herdr prefix keys, which flock already reads from
`~/.config/herdr/config.toml` and which currently raise a toast naming the
command. Those bindings start doing the real thing.

### The popover

`popover-signed-out.png`, `popover-signed-in.png`

This is the `launcher` action, and the only view that has no herdr equivalent
screen of its own... the launcher's job in a TUI is to be a menu, and in flock
it is the surface everything else hangs off.

- **Status block:** dot, handle, state word, and a chip naming the pane it acts
  on. Rooms below it. Mirrors the TUI header's two lines, including its state
  vocabulary (`working`, `idle`, `signed out`, `not signed in`).
- **Features:** Broadcast to panes, Chat peek, Quick send, Open viewer. Each
  carries its own shortcut.
- **This pane:** Sign in and Sign out as buttons, not rows. The one that applies
  is primary; the other is secondary, never hidden, so the pair reads as a state
  rather than as a changing menu.

Selecting a feature replaces the popover's content, with a back chevron. Open
viewer closes the popover and opens the URL.

### Peek

`peek.png`

Panes on chat, each with its status dot, handle, where it lives, unread count,
and a jump affordance. Rooms with unread below. Clicking a pane row is `jump`:
flock focuses that workspace, tab and pane by the ids the verb returned.

### Quick send

`quick-send.png`

Targets as chips (rooms then people, from `targets`), a message field, and a
send button carrying its own shortcut. The footer names the handle the message
will be sent as, because a pane that is not signed in cannot send and the user
should see why before typing.

### Broadcast

`broadcast.png`

The pane list with checkboxes and a select-all, then the message and a send
button. The footer counts the selection. Panes that are not signed in cannot be
selected.

### Menu bar

`menu-bar.png`

A Chat menu holding every action with its shortcut. Sign Out is dimmed when the
focused pane is not signed in, and Sign In when it is. The menu is absent
entirely when the binary is.

## Errors

A failed verb raises a flock toast naming what failed and why, and the popover
stays open with what the user typed intact. The TUI shows a result line inside
its popup; flock has a toast already and a second result surface would be a
second vocabulary for the same thing.

A broadcast with a partial result raises a toast naming the panes that did not
take it.

## Testing

- The headless verbs get Rust tests in `herdr-chat` over a faked `Runner`, the
  seam `rt.rs` already has. Each verb's JSON shape is asserted verbatim, because
  it is a contract with another repo.
- The TUI's behaviour is unchanged, so its existing tests are the guard for the
  refactor. Any test that has to change is a behaviour change to explain, not a
  test to update.
- flock's decisions (which verb an action maps to, what a status object means
  for the buttons, the popover's back-stack, absence) are pure code in
  `FlockCore`, driven in tests over parsed JSON, never over a live process.
- The process invocation sits behind a protocol so tests fake it. No test shells
  out to the real binary and none contacts `rt`.
- Every row of the degradation table gets a test, including a verb that never
  answers, which must fail on its deadline rather than hang.
- The popover's states get chrome render tests the way the rest of flock's
  surfaces do: signed in, signed out, and each feature view.

## Out of scope

- **Reading conversations in flock.** The viewer does that, and the plugin's own
  design hands off to it. flock is not getting a message stream.
- **A chat sidebar.** The popover acts on one pane and its actions are
  momentary.
- **Notifications.** flock's attention toasts are about agent status; chat
  unread is shown on the pane button and in peek.
- **`[[keys.command]]` bindings that are not chat.** flock keeps naming them in
  a toast.
- **Bundling herdr-chat inside flock.** Resolution finds an installed plugin;
  shipping one is a later decision.
