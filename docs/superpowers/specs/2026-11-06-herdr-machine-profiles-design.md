# herdr machine profiles

## Intent

herdr 0.9.5 can save remote machines (`herdr machine add mini`). herdr's own
TUI then shows each machine's workspaces under a "machines" heading. Flock
shows nothing from them: herdr merges machines in its client, so the local
server's socket, the only thing Flock reads, never mentions them.

Matt wants to work on his Mac mini's herdr from Flock with the same live,
typeable panes he gets locally. He chose to see one machine at a time: a
saved machine becomes a kind of Flock profile, and switching profiles
becomes fast to reach. A merged sidebar with Local and mini live together
was considered and set aside.

A spike on 2026-11-06 proved the transport: an SSH forward of the remote
`herdr.sock` and `herdr-client.sock` into one local directory, plus a Flock
Dev profile pointing at the forwarded `herdr.sock`, ran mini with no code
changes. Matt: "works flawlessly".

## Goals

- Every enabled saved herdr machine appears as a profile with no setup in
  Flock beyond `herdr machine add`.
- Switching to a machine profile opens the SSH forward; leaving it, or
  quitting Flock, closes it.
- A visible profile picker at the top of the sidebar, plus a keyboard
  shortcut, makes switching between Local and a machine quick.
- When the machine can't be reached, Flock says so plainly and recovers on
  its own when it comes back.

## Non-goals

- Local and remote workspaces live at the same time, or a merged sidebar.
- Needs you, notifications or board items from a machine that isn't the
  current profile.
- Moving panes between machines.
- Changing herdr. Its source is reference only.
- Keeping the tunnel or the session warm after switching away (see Open
  for later).

## Anti-goals

- A machine profile that silently starts or attaches to a local server.
  If mini is unreachable, Flock must never show this Mac's panes as if they
  were mini's, or an empty server as if mini had emptied.
- Typed socket paths or `/tmp` setup the user has to know about.
- Repo-driven features (board, chat, branch info, rt) misbehaving on remote
  paths, such as walking `/Users/<remote user>/...` on this Mac or spawning
  tools against them.

## Constraints

- Flock runs one profile, meaning one herdr server, at a time.
  `ProfileSessionController` tears the current session down before starting
  the next. This design keeps that.
- herdr derives the client socket from the API socket override, as a
  sibling `herdr-client.sock`. Both forwarded sockets must sit in one
  directory, named `herdr.sock` and `herdr-client.sock`.
- macOS caps a Unix socket path at 104 bytes. The local directory must be
  short (shape: `/tmp/flock-<uid>/<machine id prefix>/`), mode 0700.
- Child processes get `ToolPath.childEnvironment()`. Flock launched from
  the Dock has launchd's bare PATH, and `ssh-agent` may need
  `SSH_AUTH_SOCK` from it.
- Tests stay hermetic: no test spawns ssh, herdr or reaches the network.
  The machine list and the forward process go behind injectable sources.
- Custom-socket profiles already have no start target
  (`FlockApp.startTarget` returns nil for `.custom`), so no server is
  launched for them. Machine profiles keep that property.
- Takeover is unchanged: Flock attaches with `--takeover`, so a mini pane
  Flock shows is taken from herdr's TUI view of mini, as with local panes.

## Approaches

**A. Flock runs the SSH socket forward (chosen).** On switching to a
machine profile, Flock spawns
`ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o ServerAliveInterval=15 -L <dir>/herdr.sock:<remote api sock> -L <dir>/herdr-client.sock:<remote client sock> <target>`
and gives the session `<dir>/herdr.sock`. The rest of Flock (model,
events, pane bridges) runs unchanged, exactly as in the spike. All panes
share one SSH connection.

**B. Reuse herdr's SSH plumbing.** Rejected: no herdr command exposes a
forwarded client socket. `remote-api-bridge` covers only the API, and
`--machine` refuses `terminal session control`. Changing herdr is out of
bounds.

**C. SSH per command.** The model would speak through
`ssh <target> herdr remote-api-bridge` and each pane bridge would spawn
`ssh <target> herdr terminal session control`. Rejected: it adds a second
transport through the model and bridge, opens one SSH session per pane
(N handshakes on every switch), and lets panes fail one by one.

Why A, from first principles: Flock already defines a server as a socket
path. A puts everything remote in one component that produces a socket
path, so nothing after it has to care. It is also the same shape herdr's
own client uses for saved machines (`connect_saved_ssh` in
`src/remote/saved.rs` bridges SSH to a local socket and connects to that).

## Design

### Machine discovery

- Source: `herdr machine list --json`, an array of
  `{id, label, target, session, enabled, selected}`. Only `enabled`
  machines become profiles.
- Machine profiles are derived, not user-created. They are listed after
  Local and the user's own profiles, named by `label`, and keyed by the
  machine `id` so a rename in herdr keeps the profile.
- Read the list at launch and re-read it when the profile picker or
  Settings > Profiles opens.
  If the current profile's machine is removed or disabled, it stays current
  until the user switches away. It must not tear down mid-session.
- Settings > Profiles shows machine profiles as read-only rows ("managed
  by herdr machine"), with no rename or delete.

### Remote socket paths

- Ask the remote herdr instead of rebuilding its path rules: run
  `herdr session list --json` over SSH (one short command, before the
  forward) and take the `socket_path` of the machine's `session`. Flock
  already parses this output (`HerdrSessionList`). The client socket is
  `herdr-client.sock` beside it.
- Finding herdr on the remote side: a non-interactive SSH shell may lack
  `~/.local/bin` on PATH. Try `command -v herdr`, then `~/.local/bin/herdr`
  (where herdr installs itself, and where herdr's own discovery looks).
- Cache the resolved paths per machine id. On a forward failure that looks
  like a missing remote socket, drop the cache and resolve again once.

### Forward lifecycle

- A `MachineTunnel` component (app side; the process spawn sits behind a
  FlockCore protocol so state transitions are unit-testable) owns one ssh
  child per machine profile session.
- Order on switching to a machine: resolve paths, create the local
  directory, spawn ssh, wait until `<dir>/herdr.sock` accepts a
  connection (bounded, about 10 s), then start the session.
- On leaving the profile or quitting: shut the session down, then
  terminate ssh, then remove the directory.
- If ssh exits while the profile is current, the store's existing
  reconnect loop sees the socket fail. The tunnel restarts ssh with
  backoff, and the store reattaches when the socket answers. One process,
  one recovery path.
- Stale directories from a crashed Flock are cleared at startup
  (`StreamLocalBindUnlink` also handles stale socket files).

### Connection states

Machine profiles reuse `HerdrStore`'s connection states, but the banner
reads for a remote machine:

- connecting: "Connecting to mini…"
- unreachable (ssh failed or exited): "Can't reach mini." plus ssh's last
  stderr line, and the `ssh mini` hint for auth failures, mirroring
  herdr's own hints (passphrase keys need `ssh-add`; strict host keys need
  `known_hosts`).
- remote server not running: "herdr isn't running on mini." No Start
  button: starting a remote server is out of scope.

### Switching

- **Sidebar picker:** the top of the sidebar shows the current profile
  (Local, mini, user profiles) and opens a list to switch. Machine
  profiles carry a small remote marker and their connection dot.
- **Shortcut:** a keyboard shortcut opens the same list for keyboard
  selection. The exact key is the builder's call, checked against
  existing bindings.
- The Flock > Profile menu stays and gains the machine profiles.
- Switching keeps today's full teardown and rebuild.

### Preferences

Machine profiles share the Default profile's preferences suite (theme,
text size, scroll speed, starting-folder choice, rail width, link trust and
the rest), so a setting changed on either applies to both. Only per-server
id state is per machine. (Matt's call.)

### Relaunch

Flock reopens on a machine profile if it quit there. Machine profiles
persist, so at launch Flock tunnels to the stored machine at once, without
waiting for `herdr machine list`, and shows the switch loader over the
window: "Connecting to mini…" while the tunnel comes up, then "Can't reach
mini" with the reason if it fails. If a later machine list says the
machine is gone, the loader says "mini is no longer a saved herdr machine"
and offers Switch to Default. It never falls back to Default and shows
this Mac's panes in the meantime. (Matt's call.)

### Production and Dev side by side

Tunnel directories include the app's bundle id (shape:
`/tmp/flock-<uid>/<short bundle tag>-<machine id prefix>/`), so production
Flock and Flock Dev each own their forward and never unlink each other's
sockets. Startup cleanup removes only directories for this bundle. Two
Flocks on the same machine are detected by machine id and get the existing
`FlockClientGuard` prompt (Quit the other / Stay / Keep both). (My call.)

### Local-only tools on a machine profile

Hidden or disabled while the current profile is a machine (my call):

- herdr update and the mouse patch check (they compare the local binary
  with the connected server's version and hand off to it).
- Settings > Server's picker, stop and delete actions; a machine profile's
  server is fixed by herdr.
- Child tools (rt, herdr-chat, deck) never receive the forwarded socket in
  `HERDR_SOCKET_PATH`.

Version check: the local herdr runs every pane bridge against mini's
server. If the local and remote versions differ, show one plain warning
in the connection banner; do not block. (My call.)

### Local files into remote panes

- **Clipboard image paste and pasted files** (Flock has no drag-and-drop
  onto panes today, so "file drop" means files copied in Finder and
  pasted) copy the file to mini over the
  machine's SSH connection (a short `ssh <target> 'cat > <path>'` or
  equivalent) into a new private temp directory on mini, one per upload
  (`mktemp -d`), under a name reduced to plain characters, then paste the
  path mini reports. Upload failures show a short
  note in the pane chrome; nothing local is pasted instead. (Matt's call.)
- **Starting folder** on a machine profile: Home or Custom resolve on mini,
  not here. Flock omits the local cwd so herdr opens in mini's home, and
  Custom is ignored with a one-line note in Settings while on a machine.
  (My call.)
- **Cmd-click on a file path** in a remote pane does not open a local
  file. URLs still open. (My call.)
- These paths read a per-session "remote" flag. They never guess from path
  shape, since both Macs may share a home path.

### Remote paths in repo-driven features

- A machine profile session marks its panes' paths as remote. Features
  that read a pane's `cwd` against this Mac's disk or run tools there
  (board/rt, chat availability, branch info, repo walks) treat remote
  paths as "no repo" and show nothing for those panes.
- Display-only uses of cwd (titles, labels) keep working.

## Left to the builder

- The exact remote marker and picker styling, rendered in light and dark
  themes per the UI rule.
- The shortcut key.
- How derived machine profiles are stored next to `ProfileStore`
  (separate source merged at read time is the expected shape).
- Backoff numbers for tunnel restarts.

## Open for later

- If rebuild-on-switch is too slow in practice, the first step is to keep
  the previous machine's tunnel warm for a while after switching away
  (Matt's call, 2026-11-06). Live sessions side by side are a separate,
  larger project.
