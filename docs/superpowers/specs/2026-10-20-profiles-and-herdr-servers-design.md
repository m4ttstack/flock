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
workspaces mode, palette recents, the board logo cache.

**Machine-wide, shared by every profile.** Stay on `UserDefaults.standard`:

- `flock.mainWindowFrame` (the window does not close on a switch, so there is
  nothing to restore per profile)
- `flock.herdrMousePatch.offerDismissedForVersion`, the patch cache, the
  command-line tool symlink
- `flock.devRebuild.lastDuration`
- `ApplePersistenceIgnoreState` and the system keys `WindowChrome` reads
- `~/Library/Application Support/Flock/clients/` (the client registry)
- the profile list itself (section 2)

## 2. Storage

Two scopes, because a profile can change servers and come back:

- **Preferences are per profile.**
- **id-keyed state is per profile and server.** Moving a profile to another
  server shows an empty rail for that server; moving it back restores its
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
  hash of the socket path normalized with `FlockClientRecord.normalized`.
  Default's id-keyed state for a non-default socket uses this form too, with
  `default` as the id.
- Prefixing with the bundle id keeps Flock's and Flock Dev's profiles apart,
  as their standard domains already are.
- **Deleting a profile** removes its preferences suite and every server
  suite for its `knownSockets` with `removePersistentDomain`. Default cannot
  be deleted, and the current profile cannot be deleted without switching
  away first.
- **`HERDR_SOCKET_PATH` still wins** when set (tests and `e2e.sh` rely on
  it). The server picker then shows the path as fixed by the environment and
  is disabled, and so is switching profiles: flock stays on whichever
  profile was current. (My call: switching would read another profile's
  id-keyed state against the environment's server.)

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

**The two-Flocks guard runs before step 1.** `FlockClientGuard.settle`
checks the new socket first. If another Flock holds it, the alert's quit
button becomes "Stay on <current profile>", which cancels the switch and
leaves the old session untouched. Nothing is torn down until the guard
passes. (My call: quitting would break "switching never quits".)

**Child tools follow the session's socket.** Today only the bridge sets
`HERDR_SOCKET_PATH`; `herdr-chat`, `rt` and `cswap` run with
`ToolPath.childEnvironment()`, which does not, and pane ids repeat across
servers (`w1:p1` exists on both). So every child tool a session runs gets
the session's socket in `HERDR_SOCKET_PATH`, and `ChatStore` is
session-scoped, so a demo server never shows or signs in the default
server's chat. If a tool turns out not to honor the variable, Chat is
hidden on non-default servers instead. (My call.)

Teardown is the risk. A leak means a bridge still attached to the old
server, or a store writing one profile's state into another's suite, and it
would be quiet. So the session owns an explicit `shutdown()` that every
resource registers with, and acceptance below checks for leftovers.

Long-lived app objects that are not per profile (theme install, `ToolPath`,
the updater, `ChatStore` unless it proves session-bound, the client guard)
stay on `FlockApp`. Where it is unclear which side something belongs on, the
test is: does it read a profile's suite or the socket? If so, it is session.

## 4. Choosing a server

In Settings > herdr, a **Server** row for the current profile:

- A menu listing `herdr session list --json` (name, running, socket). Each
  entry shows running or stopped. The current one is checked.
- **New server…** asks for a name and starts `herdr --session <name> server`
  through `HerdrServerLauncher`, then selects it.
- **Custom socket path…** takes any path. It is stored as given.
- Re-read the list when the menu opens; nothing polls in the background.

Picking an entry saves it on the profile and switches the session in place,
onto that server's id-keyed suite for this profile (section 2).

**When the chosen server is not there.** `NoHerdrScreen` gains a third copy,
naming the session (`sessionLabel` already derives it from the path): it is
not running, flock is checking, and a **Start** button that starts that
named session through the launcher. A custom path gets no Start button,
since flock cannot know how to start it. flock keeps checking (cadence is
the builder's call; a socket connect every couple of seconds is plenty) and
attaches as soon as the server answers.

Not in scope: stopping or deleting herdr sessions from flock. That stays
with the herdr CLI.

## 5. Choosing a profile

- **Flock menu > Profile** submenu: each profile, a check on the current
  one, then **New Profile…** and **Manage Profiles…**.
- **New Profile…** asks for a name and a server (same choices as section 4,
  with New server preselected and its name defaulting to the profile name),
  creates the profile, and switches to it.
- **Manage Profiles…** opens Settings on a new **Profiles** tab: rename,
  delete, and pick each profile's server.
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
- Stopping or deleting herdr sessions.

## Anti-goals

- Any state from one profile showing up in another, or being written to
  another's suite.
- Anything left attached to the old server after a switch.
- A switch that disturbs the server being left: its panes keep running.
- flock's own process becoming the parent or session of a server it started.

## Acceptance

- With no profile list stored, flock behaves exactly as today: Default
  profile, default socket, existing settings and pins intact.
- Creating a profile on a new server and switching to it shows an empty
  rail, no dock cards, default theme and sizes, and no Board or Herds
  sections. Switching back to Default shows everything as it was, pins
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
- Moving a profile with pins to another server shows an empty rail; moving
  it back shows the same pins, symbols, completed tabs and recents.
- Deleting a profile removes its preferences suite and every server suite;
  Default cannot be deleted.
- `HERDR_SOCKET_PATH` set: flock uses it, and the server picker says so and
  is disabled.
- Tests stay hermetic: the session and profile stores take injected
  UserDefaults and sources; nothing under test starts herdr outside
  `Scripts/e2e.sh`.

## Left to the builder

- The exact session type, how commands and Settings reach the current
  session, and the order of teardown.
- Where `ChatStore`, `BoardStore` and `HerdProgressStore` sit (app or
  session), by the test in section 3.
- The not-running screen's check cadence and copy.
- Validation of profile and server names.
