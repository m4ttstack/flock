# Profiles, and choosing which herdr server flock drives

## Why this exists

flock drives one herdr server, fixed at launch: `HERDR_SOCKET_PATH` if set,
else `~/.config/herdr/herdr.sock`. There is no way to point it somewhere else
from the app, and no way to have a second set of pins, symbols and settings.

Two needs, one general and one immediate:

- **Generally useful.** Separate setups for separate kinds of work (work
  pins and personal pins, say), and attaching to herdr's other named
  sessions without relaunching from a terminal.
- **A clean demo.** Recording a showcase video means flock has to look like
  a fresh install: no personal workspaces, pins, recents, cards or titles.
  The person recording switches their one flock over to a clean profile on
  a clean server, records, and switches back.

## Decisions

- **A profile owns its herdr server.** A profile is a whole set of
  remembered state plus the socket it attaches to. Choosing a server is a
  per-profile setting. See "Why a profile owns its server" below.
- **Switching never quits flock.** Switching profile, or switching the
  current profile's server, tears down the window's session and builds a new
  one in the running app, the way VS Code reloads a window. A relaunch was
  considered and rejected as a smell.
- **One window.** Several profiles open at once in separate windows is a
  later step. Nothing here builds toward it beyond not tying the session to
  app-wide singletons where that costs nothing extra.
- **The existing setup becomes the "Default" profile in place.** No
  migration.
- **rt-powered surfaces stay as they are.** Board, Herds, Chat and cswap
  accounts are not switched off per profile. They are already scoped by the
  server: Board rows are herdr workspaces whose labels match
  `board.workspaces` and the section hides when there are none
  (`WorkspaceRail.swift`, `sections.board.isEmpty`); herds are workspaces on
  the attached server; chat is keyed by pane id; account emails show only on
  pins, and a new profile has none. A clean profile on a clean server shows
  none of them. Chat needs the child-tool change in section 3 to hold.
- **flock starts named servers itself, through `HerdrServerLauncher`.** That
  launcher already does what took trial and error to get right (its own
  session via `POSIX_SPAWN_SETSID`, stdio on /dev/null, `HERDR_MACOS_SERVER_CONTEXT=user`,
  no `RT_BATCH`, cwd at home) so the server never belongs to flock. Starting
  a named session is the same spawn with `--session <name>` before `server`
  (the form `Tests/FlockUITests/Support/bin/scratch-session.sh` uses).

### Why a profile owns its server

Ten stores hold herdr ids (workspace, tab, pane or terminal ids), all in one
UserDefaults domain with nothing saying which server they came from:
`flock.pinnedWorkspaces`, `flock.workspaceSymbol`, `flock.completedTabs`,
`flock.workspaceRecents`, `flock.tabRecents`, `flock.paneLastChange.v2`,
`flock.rt.linkedPanes`, `flock.rightClicksToMenu`, `flock.attentionToasts`,
`flock.paneTitleMemory`. Several prune entries the attached server does not
know. Pointing today's flock at another server would quietly drop completed
tabs, recents and last-change times, and pins could relink to the wrong
workspaces. Server and id-keyed state have to move together: a profile
picks the server, and its id-keyed state is kept per server within the
profile (section 2).

## 1. What a profile holds

Three groups. The builder should confirm the list against the code when
wiring it; the catalog below was taken on 2026-10-20.

**Per profile: state keyed by herdr ids.** The ten stores above.

**Per profile: preferences.** Theme, terminal text size, rt modal text sizes
and sizes, top bar label and overlay sizes, rail width, section collapse,
scroll speed, Option as Alt, trusted link schemes, notification lifetime,
one-title-for-one-pane-tab, close warnings, starting folders, rearrange after
move, Overview bottom line, Overview return, Overview inclusion, all
workspaces mode, palette recents.

**Machine-wide, shared by every profile.** Stay on `UserDefaults.standard`:

- `flock.mainWindowFrame` (the window does not close on a switch, so there is
  nothing to restore per profile)
- `flock.herdrMousePatch.offerDismissedForVersion`, the patch cache, the
  command-line tool symlink
- `flock.devRebuild.lastDuration`
- `flock.boardLogo` (deck's logo, the same for every profile)
- `ApplePersistenceIgnoreState` and the system keys `WindowChrome` reads
- `~/Library/Application Support/Flock/clients/` (the client registry)
- the profile list itself (section 2)

## 2. Storage

Two scopes, because a profile can change servers and come back:

- **Preferences are per profile.**
- **id-keyed state is per profile and server.** Moving a profile to another
  server shows no pins, symbols, completed tabs or recents, only that
  server's own workspaces; moving it back restores its
  pins, symbols, completed tabs and recents untouched. Nothing is pruned
  against a server it did not come from.

Concretely:

- **The profile list** lives on `UserDefaults.standard` under one key: an
  ordered list of `{id, name, socket, knownSockets}` plus the current
  profile's id. `knownSockets` is every socket the profile has used, so its
  suites can be found again. With no list stored, there is one profile,
  Default, on the default socket.
- **Default on the default socket** keeps both scopes on
  `UserDefaults.standard`, which is why nothing migrates. Machine-wide keys
  share that domain; their names do not overlap.
- **Any other profile's preferences** go in
  `UserDefaults(suiteName: "<bundle id>.profile.<id>")`.
- **Any other (profile, server) pair's id-keyed state** goes in
  `"<bundle id>.profile.<id>.server.<key>"`, where `<key>` is a stable short
  hash of the socket path with `~` expanded and `.`/`..` removed, without
  resolving symlinks: resolution depends on whether the socket exists (for
  `/tmp` and `/var` paths), and the key must not change with the server
  being up or down.
  Default's id-keyed state for a non-default socket uses this form too, with
  `default` as the id.
- Prefixing with the bundle id keeps Flock's and Flock Dev's profiles apart,
  as their standard domains already are.
- **Deleting a profile** removes its preferences suite and every server
  suite for its `knownSockets` with `removePersistentDomain`. Default cannot
  be deleted, and the current profile cannot be deleted without switching
  away first.
- **`HERDR_SOCKET_PATH` still wins** when set (tests and `e2e.sh` rely on
  it). flock attaches there with the current profile's preferences and
  id-keyed state from one fixed suite, `<bundle id>.override`, shared by
  every override run. The override socket is never recorded in the
  profile's `knownSockets` and never saved as its server. The server picker
  shows the path as fixed by the environment and is disabled, and so is
  switching profiles. (My call: the override pins the server for the
  launch, so neither control has anything to move. One fixed suite keeps
  e2e runs, each on a fresh scratch socket, from leaving a domain behind per
  run, and keeps them off the real Default state, which e2e's app shares a
  defaults domain with and which today's single store lets a scratch server
  prune.)

The session is built from two `UserDefaults`, preferences and id-keyed,
and hands each store the right one per section 1. Almost every store
already takes its `UserDefaults` at init, defaulting to `.standard`. Three places need a code change to take the profile's suite:
`RtLinkedPanes` (built by `RtCoordinator`'s default argument inside
`SessionViewModel`; pass `rt:` or thread the defaults through),
`WorkspaceSwitcher` / `TabSwitcher` (constructed without defaults in
`FlockApp`), and the store wiring generally (about 35 bare `Store()` calls in
`FlockApp`).

## 3. The session, and switching in place

Today `FlockApp.init` builds every store, the `HerdrStore`, `HerdrClient`,
both pane subscribers and the ghostty control surface factory, all bound to
one socket and `.standard`. Everything downstream reads them from `@State`
and the environment.

Move all of that into one session object, built from `(profile, socket)`.
`FlockApp` holds the current session; the window's content, the commands and
the Settings scene all read from it. A switch:

1. Tears down the old session: every ghostty surface closed, every
   `Flock --bridge` child ended, `HerdrStore` stopped, both subscribers
   cancelled, timers and notification observers removed, the client registry
   record updated.
2. Builds a new session from the new profile's suite and socket.
3. Rebuilds the window content from it (an identity change on the root view
   is enough; the window itself stays open).

**The two-Flocks guard runs before step 1.** The guard checks the new
socket first. If another Flock holds it, the alert's quit button becomes
"Stay on <current profile name>" for a profile switch, or "Stay on
<current server label>" when only the current profile's server changes.
Either cancels the switch. Nothing is torn down, and nothing is saved (not
the current profile id, not a profile's server), until the guard passes,
so a cancel leaves the next launch where this one was. (My call: quitting
would break "switching never quits".)

**Child tools follow the session's socket.** Today only the bridge sets
`HERDR_SOCKET_PATH`; `herdr-chat`, `rt` and `cswap` run with
`ToolPath.childEnvironment()`, which does not, and pane ids repeat across
servers (`w1:p1` exists on both). So every child tool a session runs gets
the session's socket in `HERDR_SOCKET_PATH`, and `ChatStore` is
session-scoped, so a demo server never shows or signs in the default
server's chat. If a tool turns out not to honor the variable, Chat is
hidden on non-default servers instead. (My call.)

The one exception is the server launcher: a server's environment becomes
every one of its panes' shells, so it gets the socket of the server being
started, never the current session's. The default server and named
sessions start with `HERDR_SOCKET_PATH` removed, so their panes' shells
see what they see today (herdr ranks the variable above `HERDR_SESSION`).
A named session runs `herdr --session <name> server` after creating
`~/.config/herdr/sessions/<name>/` if missing, as `scratch-session.sh`
does. The one case with the variable set is an override socket of custom
shape: it keeps today's Start button, which runs `herdr server` with
`HERDR_SOCKET_PATH` set to that socket. A custom socket chosen in the
picker gets no Start button (section 4).

Teardown is the risk. A leak means a bridge still attached to the old
server, or a store writing one profile's state into another's suite, and it
would be quiet. So the session owns an explicit `shutdown()` that every
resource registers with, and acceptance below checks for leftovers.
Teardown also flushes pending writes before the session goes (pane titles
save on a two second delay), and nothing app-level keeps a reference to an
old session (`FlockAppDelegate.onTerminate` reads the current session
rather than capturing the first one).

Long-lived app objects that are not per profile (theme install, `ToolPath`,
the updater, the client guard, `BoardStore`, `HerdProgressStore`,
`CswapStore`) stay on `FlockApp`. `ChatStore` is per session (above).
Where it is unclear which side something belongs on, the test is: does it
read a profile's suite or the socket? If so, it is session.

## 4. Choosing a server

In Settings > herdr, a **Server** row for the current profile:

- A menu listing `herdr session list --json` (name, running, socket). Each
  entry shows running or stopped. The current one is checked.
- **New server…** asks for a name and starts `herdr --session <name> server`
  through `HerdrServerLauncher`, then selects it.
- **Custom socket path…** takes any path. It is stored as given.
- Re-read the list when the menu opens; nothing polls in the background.

Picking an entry switches the session in place, onto that server's
id-keyed suite for this profile (section 2), and saves it on the profile
once the guard (section 3) passes.

Whether a socket is the default server, a named session or a custom path
is read from its shape alone: `~/.config/herdr/herdr.sock` is the default,
`~/.config/herdr/sessions/<name>/herdr.sock` is session `<name>`, anything
else is custom. Only custom paths lack a Start button.

**When the chosen server is not there.** `NoHerdrScreen` gains a third copy,
naming the session (`sessionLabel` already derives it from the path): it is
not running, flock is checking, and a **Start** button that starts that
named session through the launcher. A custom path gets no Start button,
since flock cannot know how to start it. flock keeps checking (cadence is
the builder's call; a socket connect every couple of seconds is plenty) and
attaches as soon as the server answers.

**Stopping and deleting servers.** Settings > herdr lists every named
session from `herdr session list` under a **Servers** section, each with
running or stopped beside its name:

- A running session has **Stop**, which runs `herdr session stop <name>`.
- A stopped session has **Delete**, which runs `herdr session delete <name>`
  (herdr refuses to delete a running one).
- Both ask first. Stop says every pane and agent on that server closes;
  Delete says its saved workspaces go. Neither can be undone.
- Neither is offered for the default server, for the server this flock is
  on, or for a server another running Flock's registry record names. Those
  rows say why instead. (My call: stopping the server under your own window,
  or under another Flock, is never what a cleanup click means.)
- A profile whose server was deleted keeps pointing at it; picking that
  profile shows the not-running screen, and Start creates the session again.
  The Delete confirmation names the profiles that use it.
- Both run by session name with `HERDR_SOCKET_PATH` removed, like the list,
  so neither can reach a server other than the one named. The list
  refreshes after each.

(Updated 2026-10-20 at Matt's request during the walkthrough; this reverses
the earlier "not in scope".)

## 5. Choosing a profile

- **Flock menu > Profile** submenu: each profile, a check on the current
  one, then **New Profile…** and **Manage Profiles…**.
- **New Profile…** asks for a name and a server (same choices as section 4,
  with New server preselected and its name defaulting to the profile name),
  creates the profile, and switches to it. If the two-Flocks prompt
  refuses the switch, the new profile stays in the list, not current.
- **Manage Profiles…** opens Settings on a new **Profiles** tab: rename,
  delete, and pick each profile's server. Picking a server for a profile
  that is not current only saves it; nothing switches.
- The profile name shows in that menu and in Settings, nowhere in the window
  chrome. The status line already shows `herdr · <session>`; that stays.
- A new profile starts as clean as a first launch: default preferences, no
  pins, no symbols, no recents, no cards.

## Non-goals

- Several windows, or several profiles open at once.
- Hot-swapping without rebuilding the window content.
- Copying preferences from one profile to another. (My call: a clean
  profile is the point of the first use, and this can come later.)
- Per-profile control of Board, Herds, Chat or cswap.
- What runs inside panes. A demo server's shells still use the user's own
  shell config, prompt and history; isolating those is a recording-setup
  concern (a different `HOME` or `ZDOTDIR` for that server), not flock's.
- Stopping the default server, or deleting a session that is running.

## Anti-goals

- Any state from one profile showing up in another, or being written to
  another's suite.
- Anything left attached to the old server after a switch.
- A switch that disturbs the server being left: its panes keep running.
- flock's own process becoming the parent or session of a server it started.

## Acceptance

- With no profile list stored, flock behaves exactly as today: Default
  profile, default socket, existing settings and pins intact.
- Creating a profile on a new server and switching to it shows no pins,
  only the fresh server's own first workspace, no dock cards, no chat
  state, default theme and sizes, and no Board or Herds sections. Switching back to Default shows everything as it was, pins
  linked to the same workspaces, completed tabs and recents intact.
- Switching profile or server leaves flock running, the window open and in
  place.
- After a switch, no `Flock --bridge` child and no subscriber connection
  points at the old socket, and the client registry names the new socket.
- A server started from flock survives quitting flock and is not in flock's
  process group or session.
- Picking a stopped session shows the not-running screen naming it; Start
  brings it up and flock attaches without further action. Starting it from
  a terminal instead also attaches.
- A custom socket path that does not exist shows the not-running screen with
  no Start button, and attaches when something binds there.
- Moving a profile with pins to another server shows none of its pins,
  symbols, completed tabs or recents; moving it back shows them all again.
- A refused two-Flocks prompt leaves the current profile, its server and
  the next launch unchanged.
- Deleting a profile removes its preferences suite and every server suite;
  Default cannot be deleted.
- Settings > herdr > Servers stops a running named session and deletes a
  stopped one, each after a confirmation. Neither is offered for the
  default server, the current one, or one another Flock is on, and the
  list shows the change.
- `HERDR_SOCKET_PATH` set: flock uses it with id-keyed state from
  `<bundle id>.override`, the server picker says so and is disabled, profile
  switching is disabled, and no profile's saved server or `knownSockets`
  changes.
- Tests stay hermetic: the session and profile stores take injected
  UserDefaults and sources; nothing under test starts herdr outside
  `Scripts/e2e.sh`.

## Left to the builder

- The exact session type, how commands and Settings reach the current
  session, and the order of teardown.
- The not-running screen's check cadence and copy.
- Validation of profile and server names.
