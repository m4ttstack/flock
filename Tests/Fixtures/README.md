# Fixtures

Real captures from a scratch `herdr` server, taken over its unix-socket NDJSON
API. No live-session content and no personal data: every pane in these
captures ran in `/tmp` and printed only synthetic `printf` output.

## Provenance

- `herdr --version`: `herdr 0.8.0`
- Socket protocol: `19` (from `herdr api schema --json`, top-level `protocol` field)
- Schema version: `1` (top-level `schema_version` field)
- Captured: 2026-09-10, against a scratch session started with
  `spikes/lib/scratch-session.sh start fixtures` (never the default
  `~/.config/herdr/herdr.sock`).

## Files

- `snapshot.json`: response to `session.snapshot` after `seed-layout.sh`
  built the canonical layout (one workspace, tabA with two side-by-side
  panes, tabB with one pane).
- `events.ndjson`: a `events.subscribe` stream (types: `layout.updated`,
  `pane.updated`, and the lifecycle types `workspace.created`,
  `workspace.closed`, `workspace.renamed`, `tab.created`, `tab.closed`,
  `tab.renamed`, `pane.created`, `pane.closed`, `pane.moved`,
  `pane.focused`) covering one `seed-layout.sh` run plus a `pane.move` to
  `new_tab`. The first few lines are the server's initial `layout.updated`
  state-sync for tabs that already existed when the subscription opened;
  everything after reflects the workspace/tab/pane creation and the move.
- `observe.ndjson`: 34 frames from
  `herdr terminal session observe <pane> --cols 80 --rows 24`, one `full:
  true` frame followed by 33 incremental frames, produced by running several
  `printf` commands (including ANSI red) in the observed pane via
  `herdr pane run`.

## Recapture commands

Run everything from the repo root. Never point any of this at
`~/.config/herdr/herdr.sock`; only at a scratch session's socket.

```bash
# 1. Start a scratch session and seed the canonical layout.
sock=$(spikes/lib/scratch-session.sh start fixtures)
map=$(spikes/lib/seed-layout.sh "$sock")
p1=$(jq -r .p1 <<<"$map")
echo "$map"

# 2. snapshot.json
printf '%s\n' '{"id":"f1","method":"session.snapshot","params":{}}' \
  | nc -U "$sock" | head -1 | jq . > Tests/Fixtures/snapshot.json

# 3. events.ndjson
# nc buffers stdout when it isn't a tty, so a long-lived subscription must
# be read with a client that flushes per line. This one-liner works:
python3 - "$sock" Tests/Fixtures/events.ndjson <<'PY' &
import socket, sys
sock_path, out_path = sys.argv[1], sys.argv[2]
sub = '{"id":"e1","method":"events.subscribe","params":{"subscriptions":[{"type":"layout.updated"},{"type":"pane.updated"},{"type":"workspace.created"},{"type":"workspace.closed"},{"type":"workspace.renamed"},{"type":"tab.created"},{"type":"tab.closed"},{"type":"tab.renamed"},{"type":"pane.created"},{"type":"pane.closed"},{"type":"pane.moved"},{"type":"pane.focused"}]}}'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall((sub + "\n").encode())
buf = b""
with open(out_path, "ab", buffering=0) as f:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            f.write(line + b"\n")
PY
subpid=$!
sleep 0.5
map2=$(spikes/lib/seed-layout.sh "$sock")
p1b=$(jq -r .p1 <<<"$map2")
sleep 0.3
printf '%s\n' "{\"id\":\"m1\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1b\",\"destination\":{\"type\":\"new_tab\"}}}" \
  | nc -U "$sock" | head -1
sleep 1
kill "$subpid"

# 4. observe.ndjson
HERDR_SOCKET_PATH="$sock" herdr terminal session observe "$p1" --cols 80 --rows 24 \
  > Tests/Fixtures/observe.ndjson &
obspid=$!
sleep 0.5
for i in $(seq 1 10); do
  HERDR_SOCKET_PATH="$sock" herdr pane run "$p1" "printf 'line $i \033[31mred\033[0m done\n'"
  sleep 0.3
done
sleep 1
kill "$obspid"

# 5. Clean up.
spikes/lib/scratch-session.sh stop fixtures
```
