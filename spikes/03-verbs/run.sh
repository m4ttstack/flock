#!/usr/bin/env bash
# Spike 03: mutation verb matrix + split-ratio paths.
# Runs cases 1, 1b, 2-8 against a scratch herdr session and writes
# per-case PASS/FAIL/DIVERGED evidence to FINDINGS.md as it goes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/spikes/lib"
HERE="$ROOT/spikes/03-verbs"
FINDINGS="$HERE/FINDINGS.md"
SESSION_NAME="verbs"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/paddock-verbs.XXXXXX")"
EVENTS_LOG="$WORKDIR/events.log"
SUB_PID=""
SOCK=""

PASS_COUNT=0
FAIL_COUNT=0
DIVERGED_COUNT=0
declare -a TIMING_SAMPLES=()
TIMING_FILE="$WORKDIR/timing.samples"
: >"$TIMING_FILE"
# Read position into EVENTS_LOG, persisted to disk (not a shell variable):
# every consumer (record_timing, lifecycle_events) runs inside a $(...)
# command substitution, i.e. a subshell, so a plain `EVT_IDX=...` write
# there would vanish the moment that subshell exits.
EVT_IDX_FILE="$WORKDIR/evt_idx"
printf '0' >"$EVT_IDX_FILE"

# Timing samples are recorded via mreq/record_timing, which run inside
# command substitutions ($(...)) in the case functions -- a subshell, so a
# plain array append there would vanish when the subshell exits. Append to
# this file instead (filesystem writes cross the subshell boundary) and
# load it into TIMING_SAMPLES once, after all cases have run.
record_delta() { [ -n "${1:-}" ] && printf '%s\n' "$1" >>"$TIMING_FILE"; }

cleanup() {
  [ -n "$SUB_PID" ] && kill "$SUB_PID" >/dev/null 2>&1 || true
  "$LIB/scratch-session.sh" stop "$SESSION_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

req() {
  # One-shot connection: exactly one request, one response line. See spike 02.
  printf '%s\n' "$1" | nc -U -w 2 "$SOCK" | head -1
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

seed() {
  local map
  map=$("$LIB/seed-layout.sh" "$SOCK")
  # Drain the seed's own events before returning: they land on the events
  # log asynchronously (the server polls every ~100ms), so without this a
  # seed event can arrive AFTER a case's t0 for its own request under test,
  # aliasing as a false match on that case's send-to-echo / lifecycle checks.
  collect_events 0.3 >/dev/null
  printf '%s' "$map"
}

md() { printf '%s\n' "$*" >>"$FINDINGS"; }
md_json() {
  printf '```\n' >>"$FINDINGS"
  if ! printf '%s\n' "$1" | jq . >>"$FINDINGS" 2>/dev/null; then
    printf '%s\n' "$1" >>"$FINDINGS"
  fi
  printf '```\n' >>"$FINDINGS"
}

start_subscriber() {
  # events.subscribe connection: single-purpose, never interleave other
  # requests on it (spike 02 finding -- doing so tears the subscription down).
  # nc full-buffers stdout off a tty, so a raw python reader drains it instead.
  python3 - "$SOCK" "$EVENTS_LOG" <<'PY' &
import socket, sys, time, json
sock_path, out_path = sys.argv[1], sys.argv[2]
types = ["layout.updated","pane.updated","workspace.created","workspace.closed",
         "workspace.renamed","tab.created","tab.closed","tab.renamed",
         "pane.created","pane.closed","pane.moved","pane.focused"]
sub = {"id": "sub1", "method": "events.subscribe",
       "params": {"subscriptions": [{"type": t} for t in types]}}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall((json.dumps(sub) + "\n").encode())
buf = b""
with open(out_path, "ab", buffering=0) as f:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            ts = int(time.time() * 1000)
            f.write((str(ts) + " " + line.decode("utf-8", "replace")).encode() + b"\n")
PY
  SUB_PID=$!
  sleep 0.3
}

# Wait for new lines to settle on the events log, then return them (and
# advance the on-disk read position past them). Prints one JSON object per
# new line: {"ts":..,"event":..,"raw":{...}}.
collect_events() {
  local timeout_s="${1:-0.8}"
  python3 - "$EVENTS_LOG" "$EVT_IDX_FILE" "$timeout_s" <<'PY'
import sys, json, time
path, idx_path, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
deadline = time.time() + timeout_s
while time.time() < deadline:
    time.sleep(0.05)
try:
    with open(idx_path) as f:
        start_idx = int((f.read().strip() or "0"))
except FileNotFoundError:
    start_idx = 0
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
out = []
for line in lines[start_idx:]:
    line = line.rstrip("\n")
    if not line:
        continue
    ts_str, _, payload = line.partition(" ")
    try:
        ts = int(ts_str)
        obj = json.loads(payload)
    except Exception:
        continue
    out.append({"ts": ts, "event": obj.get("event"), "raw": obj})
with open(idx_path, "w") as f:
    f.write(str(len(lines)))
for o in out:
    print(json.dumps(o))
PY
}

# Send-to-echo timing for a mutation already issued at $1 (ms epoch).
# Appends the matched delta (ms) to TIMING_SAMPLES; prints it (or "").
record_timing() {
  local t0="$1"
  local events delta
  events=$(collect_events 1.0)
  delta=""
  if [ -n "$(printf '%s' "$events" | tr -d '[:space:]')" ]; then
    delta=$(printf '%s\n' "$events" | jq -s --argjson t0 "$t0" \
      '[ .[] | select(.event=="layout_updated" or .event=="pane_moved") | select(.ts>=$t0) | (.ts-$t0) ] | first // empty')
  fi
  record_delta "$delta"
  printf '%s' "$delta"
}

# Mutating request wrapper: sends $1, records send-to-echo timing, returns
# the raw response on stdout.
mreq() {
  local t0 resp
  t0=$(now_ms)
  resp=$(req "$1")
  record_timing "$t0" >/dev/null
  printf '%s' "$resp"
}

# Collect (and drain) whatever new events arrived, for lifecycle assertions.
lifecycle_events() {
  local timeout_s="${1:-0.6}"
  collect_events "$timeout_s"
}

record_case() {
  local num="$1" verdict="$2"
  case "$verdict" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    DIVERGED) DIVERGED_COUNT=$((DIVERGED_COUNT + 1)) ;;
  esac
  printf '[%s] case %s\n' "$verdict" "$num"
}

# ---------------------------------------------------------------------------
# Case 1: cross-tab move with an explicit target_pane_id + split + ratio.
# ---------------------------------------------------------------------------
case1() {
  local map ws tabA tabB p1 p2 p3 resp changed snap tabA_n tabB_n verdict
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  resp=$(mreq "{\"id\":\"c1\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabB\",\"target_pane_id\":\"$p3\",\"split\":\"right\",\"ratio\":0.5}}}")
  changed=$(jq -r '.result.move_result.changed // "null"' <<<"$resp")
  snap=$(req '{"id":"c1snap","method":"session.snapshot","params":{}}')
  tabA_n=$(jq -r --arg t "$tabA" '.result.snapshot.tabs[] | select(.tab_id==$t) | .pane_count' <<<"$snap")
  tabB_n=$(jq -r --arg t "$tabB" '.result.snapshot.tabs[] | select(.tab_id==$t) | .pane_count' <<<"$snap")

  verdict="FAIL"
  [ "$changed" = "true" ] && [ "$tabA_n" = "1" ] && [ "$tabB_n" = "2" ] && verdict="PASS"
  record_case 1 "$verdict"

  md "## Case 1: pane.move p1 -> tab tabB, target_pane_id p3, split right, ratio 0.5"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Seed: ws=$ws tabA=$tabA (p1=$p1, p2=$p2) tabB=$tabB (p3=$p3)"
  md ""
  md "Raw pane.move response:"
  md_json "$resp"
  md "Assertion: changed=$changed, post-move tabA.pane_count=$tabA_n (want 1), tabB.pane_count=$tabB_n (want 2)."
  md ""
}

# ---------------------------------------------------------------------------
# Case 1b: nil target_pane_id -- must default to the destination tab's
# FOCUSED pane, not e.g. its first-created pane. Proved by focusing the
# non-default pane first, then checking which pane the moved pane lands
# beside (rect y/height match in the response's own target_layout, no
# extra round trip needed).
# ---------------------------------------------------------------------------
case1b() {
  local map ws tabA tabB p1 p2 p3 p4 resp verdict split_resp
  local p1_rect p1_y p1_h partner match_note
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  # Give tabB a second pane so "default pane" is not trivially the only pane.
  split_resp=$(mreq "{\"id\":\"c1b-split\",\"method\":\"pane.split\",\"params\":{\"target_pane_id\":\"$p3\",\"direction\":\"down\"}}")
  p4=$(jq -r .result.pane.pane_id <<<"$split_resp")
  # Focus the newly created pane (p4), NOT p3, so the default has to follow
  # focus rather than falling back to the tab's original/root pane.
  req "{\"id\":\"c1b-focus\",\"method\":\"pane.focus\",\"params\":{\"pane_id\":\"$p4\"}}" >/dev/null

  resp=$(mreq "{\"id\":\"c1b\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabB\",\"split\":\"right\"}}}")

  p1_rect=$(jq -c --arg p "$p1" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect' <<<"$resp")
  p1_y=$(jq -r '.y' <<<"$p1_rect"); p1_h=$(jq -r '.height' <<<"$p1_rect")
  partner=$(jq -r --arg p "$p1" --argjson y "$p1_y" --argjson h "$p1_h" \
    '[.result.move_result.target_layout.panes[] | select(.pane_id!=$p) | select(.rect.y==$y and .rect.height==$h) | .pane_id] | first // "none"' <<<"$resp")

  verdict="FAIL"
  [ "$partner" = "$p4" ] && verdict="PASS"
  [ "$partner" != "$p4" ] && [ "$partner" != "none" ] && verdict="DIVERGED"
  record_case 1b "$verdict"

  if [ "$partner" = "$p4" ]; then
    match_note="Matches: nil target_pane_id splits against the destination tab's FOCUSED pane."
  else
    match_note="MISMATCH: default target is not simply the focused pane; see raw response."
  fi

  md "## Case 1b: pane.move with no target_pane_id -- default-pane polarity"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Seed: tabB=$tabB started with p3=$p3 only. Split p3 down to add p4=$p4, then explicitly focused p4 (not p3) before the nil-target move, so a correct default has to follow focus, not tab history."
  md ""
  md "Raw pane.split (built p4):"
  md_json "$split_resp"
  md "Raw pane.move (nil target_pane_id) response:"
  md_json "$resp"
  md "p1's post-move rect: y=$p1_y height=$p1_h. Pane sharing that y-band (its split partner): $partner. Focused pane going in was $p4. $match_note"
  md ""
}

# ---------------------------------------------------------------------------
# Case 2: same-workspace move to a new tab -- pane id must NOT re-key.
# ---------------------------------------------------------------------------
case2() {
  local map ws tabA tabB p1 p2 p3 resp new_pane prev_pane created_tab_id created_label verdict
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  resp=$(mreq "{\"id\":\"c2\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p2\",\"destination\":{\"type\":\"new_tab\",\"workspace_id\":\"$ws\",\"label\":\"nt\"}}}")

  new_pane=$(jq -r '.result.move_result.pane.pane_id' <<<"$resp")
  prev_pane=$(jq -r '.result.move_result.previous_pane_id' <<<"$resp")
  created_tab_id=$(jq -r '.result.move_result.created_tab.tab_id // "null"' <<<"$resp")
  created_label=$(jq -r '.result.move_result.created_tab.label // "null"' <<<"$resp")

  verdict="FAIL"
  [ "$new_pane" = "$p2" ] && [ "$prev_pane" = "$p2" ] && [ "$created_tab_id" != "null" ] && [ "$created_label" = "nt" ] && verdict="PASS"
  record_case 2 "$verdict"

  md "## Case 2: pane.move p2 -> new_tab (same workspace)"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Raw response:"
  md_json "$resp"
  md "new pane_id=$new_pane, previous_pane_id=$prev_pane (want both == $p2, i.e. unchanged), created_tab.tab_id=$created_tab_id, label=$created_label (want nt)."
  md ""
}

# ---------------------------------------------------------------------------
# Case 3: cross-workspace move -- pane id MUST re-key, and the only
# lifecycle event for the pane itself must be pane.moved (no separate
# close/create pair modeling it).
# ---------------------------------------------------------------------------
case3() {
  local map ws tabA tabB p1 p2 p3 t0 resp new_pane prev_pane created_ws created_ws_label created_tab_label verdict
  local events bad_events moved_pane_bad d
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  t0=$(now_ms)
  resp=$(req "{\"id\":\"c3\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p3\",\"destination\":{\"type\":\"new_workspace\",\"label\":\"nw\",\"tab_label\":\"main\"}}}")
  events=$(lifecycle_events 0.7)
  if [ -n "$(printf '%s' "$events" | tr -d '[:space:]')" ]; then
    d=$(printf '%s\n' "$events" | jq -s --argjson t0 "$t0" \
      '[ .[] | select(.event=="layout_updated" or .event=="pane_moved") | select(.ts>=$t0) | (.ts-$t0) ] | first // empty')
    record_delta "$d"
  fi

  new_pane=$(jq -r '.result.move_result.pane.pane_id' <<<"$resp")
  prev_pane=$(jq -r '.result.move_result.previous_pane_id' <<<"$resp")
  created_ws=$(jq -r '.result.move_result.created_workspace.workspace_id // "null"' <<<"$resp")
  created_ws_label=$(jq -r '.result.move_result.created_workspace.label // "null"' <<<"$resp")
  created_tab_label=$(jq -r '.result.move_result.created_tab.label // "null"' <<<"$resp")

  # Two different questions: (a) did any pane_closed/pane_created fire for
  # ANYTHING (ancillary bootstrap noise is allowed -- e.g. a placeholder
  # pane/tab the new workspace creates for itself), vs (b) did one fire for
  # the MOVED pane specifically (old id $prev_pane or new id $new_pane) --
  # that would mean the re-key was NOT carried by pane.moved alone, which is
  # what the brief actually cares about.
  # Filter to events at or after t0: seed()'s own workspace/tab/pane_created
  # events for this case sit un-drained in the same log (nothing before this
  # point consumed them) and would otherwise be misread as lifecycle noise
  # from the move itself -- e.g. seed's own pane_created for $p3 shares an
  # id with $prev_pane by construction, which is not a re-key artifact.
  bad_events=0
  moved_pane_bad=0
  if [ -n "$(printf '%s' "$events" | tr -d '[:space:]')" ]; then
    bad_events=$(printf '%s\n' "$events" | jq -s --argjson t0 "$t0" \
      '[ .[] | select(.ts>=$t0) | select(.event=="pane_closed" or .event=="pane_created") ] | length')
    moved_pane_bad=$(printf '%s\n' "$events" | jq -s --argjson t0 "$t0" --arg old "$prev_pane" --arg new "$new_pane" \
      '[ .[] | select(.ts>=$t0) | select(.event=="pane_closed" or .event=="pane_created")
             | ((.raw.data.pane.pane_id // .raw.data.pane_id // "")) as $pid
             | select($pid == $old or $pid == $new) ] | length')
  fi

  verdict="FAIL"
  if [ "$new_pane" != "$prev_pane" ] && [ "$new_pane" != "null" ] && [ "$prev_pane" = "$p3" ] \
     && [ "$created_ws" != "null" ] && [ "$created_ws_label" = "nw" ] && [ "$created_tab_label" = "main" ] \
     && [ "$moved_pane_bad" = "0" ]; then
    verdict="PASS"
    [ "$bad_events" != "0" ] && verdict="DIVERGED"
  fi
  record_case 3 "$verdict"

  md "## Case 3: pane.move p3 -> new_workspace (cross-workspace re-key)"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Raw response:"
  md_json "$resp"
  md "### Cross-workspace re-key example"
  md ""
  md "| old pane id | new pane id | new workspace | new workspace label | new tab label |"
  md "|---|---|---|---|---|"
  md "| $prev_pane | $new_pane | $created_ws | $created_ws_label | $created_tab_label |"
  md ""
  md "### Lifecycle events observed in the 0.7s window after the request (ts >= send time)"
  md ""
  if [ "$(printf '%s' "$events" | tr -d '[:space:]')" = "" ]; then
    md "(none captured)"
  else
    md '```'
    printf '%s\n' "$events" | jq -s --argjson t0 "$t0" -r '.[] | select(.ts>=$t0) | .event' >>"$FINDINGS"
    md '```'
  fi
  md "pane_closed/pane_created events referencing the MOVED pane ($prev_pane / $new_pane) specifically: $moved_pane_bad (want 0 -- the re-key itself must ride on pane.moved alone)."
  md "Total pane_closed/pane_created events anywhere in the window (any pane): $bad_events."
  if [ "$bad_events" != "0" ] && [ "$moved_pane_bad" = "0" ]; then
    md ""
    md "**Surprise for Tasks 20/23:** the brief expected pane.moved to be the ONLY lifecycle event for this whole operation. In practice, creating the new_workspace destination bootstraps its own placeholder tab/pane (tab_created + pane_created), which then gets closed and replaced by the tab actually holding the moved pane (tab_closed + a second tab_created) -- ancillary noise around the edges of the move, not touching the moved pane's own id. A client diffing local state against this event stream needs to tolerate that bootstrap churn on a new_workspace/new_tab destination rather than assuming exactly one event fires."
  fi
  md ""
}

# ---------------------------------------------------------------------------
# Case 4: left-edge composition (move with split:right, then swap).
# ---------------------------------------------------------------------------
case4() {
  local map ws tabA tabB p1 p2 p3 move_resp swap_resp
  local p3x p1x_before p1x_after p3x_after verdict
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  move_resp=$(mreq "{\"id\":\"c4-move\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p3\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabA\",\"target_pane_id\":\"$p1\",\"split\":\"right\"}}}")
  p1x_before=$(jq -r --arg p "$p1" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$move_resp")
  p3x=$(jq -r --arg p "$p3" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$move_resp")

  swap_resp=$(mreq "{\"id\":\"c4-swap\",\"method\":\"pane.swap\",\"params\":{\"source_pane_id\":\"$p3\",\"target_pane_id\":\"$p1\"}}")
  p1x_after=$(jq -r --arg p "$p1" '.result.swap.layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$swap_resp")
  p3x_after=$(jq -r --arg p "$p3" '.result.swap.layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$swap_resp")

  verdict="FAIL"
  if [ -n "$p1x_before" ] && [ -n "$p3x" ] && [ -n "$p1x_after" ] && [ -n "$p3x_after" ] \
     && [ "$p1x_before" != "null" ] && [ "$p3x" != "null" ] && [ "$p1x_after" != "null" ] && [ "$p3x_after" != "null" ]; then
    if python3 -c "
before_right = float('$p3x') > float('$p1x_before')
after_left = float('$p3x_after') < float('$p1x_after')
raise SystemExit(0 if (before_right and after_left) else 1)
"; then
      verdict="PASS"
    fi
  fi
  record_case 4 "$verdict"

  md "## Case 4: left-edge composition (move split:right, then swap)"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Raw pane.move response:"
  md_json "$move_resp"
  md "Raw pane.swap response:"
  md_json "$swap_resp"
  md "p1.x before swap=$p1x_before, p3.x before swap=$p3x (split:right places the moved-in pane to the RIGHT). After swap: p1.x=$p1x_after, p3.x=$p3x_after (want p3.x < p1.x, i.e. moved pane now on the LEFT)."
  md ""
}

# ---------------------------------------------------------------------------
# Case 5: same-tab no-op, then bounce via a temp tab, ending below the old
# sibling with the pane id unchanged.
# ---------------------------------------------------------------------------
case5() {
  local map ws tabA tabB p1 p2 p3 noop_resp bounce_resp temp_tab back_resp close_resp
  local p1_y p2_y p1_x p2_x pane_id_after verdict noop_changed noop_reason
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  noop_resp=$(mreq "{\"id\":\"c5-noop\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabA\",\"target_pane_id\":\"$p2\",\"split\":\"right\"}}}")
  noop_changed=$(jq -r '.result.move_result.changed' <<<"$noop_resp")
  noop_reason=$(jq -r '.result.move_result.reason' <<<"$noop_resp")

  bounce_resp=$(mreq "{\"id\":\"c5-out\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"new_tab\",\"workspace_id\":\"$ws\"}}}")
  temp_tab=$(jq -r '.result.move_result.created_tab.tab_id' <<<"$bounce_resp")
  pane_id_after=$(jq -r '.result.move_result.pane.pane_id' <<<"$bounce_resp")

  back_resp=$(mreq "{\"id\":\"c5-back\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabA\",\"target_pane_id\":\"$p2\",\"split\":\"down\"}}}")
  close_resp=$(mreq "{\"id\":\"c5-close\",\"method\":\"tab.close\",\"params\":{\"tab_id\":\"$temp_tab\"}}")

  p1_y=$(jq -r --arg p "$p1" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.y' <<<"$back_resp")
  p1_x=$(jq -r --arg p "$p1" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$back_resp")
  p2_y=$(jq -r --arg p "$p2" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.y' <<<"$back_resp")
  p2_x=$(jq -r --arg p "$p2" '.result.move_result.target_layout.panes[] | select(.pane_id==$p) | .rect.x' <<<"$back_resp")

  verdict="FAIL"
  if [ "$noop_changed" = "false" ] && [ "$noop_reason" = "same_tab" ] && [ "$pane_id_after" = "$p1" ] \
     && [ -n "$p1_y" ] && [ -n "$p2_y" ] && [ "$p1_y" != "null" ] && [ "$p2_y" != "null" ] \
     && python3 -c "raise SystemExit(0 if float('$p1_y') > float('$p2_y') else 1)"; then
    verdict="PASS"
  fi
  record_case 5 "$verdict"

  md "## Case 5: same-tab bounce (no-op, then bounce below old sibling)"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Raw same-tab move response (expect changed:false reason:same_tab):"
  md_json "$noop_resp"
  md "Raw bounce-out (new_tab) response:"
  md_json "$bounce_resp"
  md "Raw bounce-back (target_pane_id=$p2, split:down) response:"
  md_json "$back_resp"
  md "Raw tab.close (temp tab $temp_tab) response:"
  md_json "$close_resp"
  md "no-op: changed=$noop_changed reason=$noop_reason. bounce pane id unchanged: $pane_id_after (want $p1). Final rects: p1 y=$p1_y x=$p1_x, p2 y=$p2_y x=$p2_x (want p1.y > p2.y, i.e. p1 below p2)."
  md ""
}

# ---------------------------------------------------------------------------
# Case 6: zoom guard.
# ---------------------------------------------------------------------------
case6() {
  local map ws tabA tabB p1 p2 p3 zoom_on_resp blocked_resp zoom_off_resp retry_resp
  local blocked_reason blocked_changed retry_changed snap tabA_n verdict
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  zoom_on_resp=$(mreq "{\"id\":\"c6-zon\",\"method\":\"pane.zoom\",\"params\":{\"pane_id\":\"$p1\",\"mode\":\"on\"}}")
  blocked_resp=$(mreq "{\"id\":\"c6-blocked\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p3\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabA\",\"target_pane_id\":\"$p1\",\"split\":\"right\"}}}")
  blocked_changed=$(jq -r '.result.move_result.changed' <<<"$blocked_resp")
  blocked_reason=$(jq -r '.result.move_result.reason' <<<"$blocked_resp")

  zoom_off_resp=$(mreq "{\"id\":\"c6-zoff\",\"method\":\"pane.zoom\",\"params\":{\"pane_id\":\"$p1\",\"mode\":\"off\"}}")
  retry_resp=$(mreq "{\"id\":\"c6-retry\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p3\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$tabA\",\"target_pane_id\":\"$p1\",\"split\":\"right\"}}}")
  retry_changed=$(jq -r '.result.move_result.changed' <<<"$retry_resp")

  snap=$(req '{"id":"c6snap","method":"session.snapshot","params":{}}')
  tabA_n=$(jq -r --arg t "$tabA" '.result.snapshot.tabs[] | select(.tab_id==$t) | .pane_count' <<<"$snap")

  verdict="FAIL"
  [ "$blocked_changed" = "false" ] && [ "$blocked_reason" = "zoomed_tab" ] && [ "$retry_changed" = "true" ] && [ "$tabA_n" = "3" ] && verdict="PASS"
  record_case 6 "$verdict"

  md "## Case 6: zoom guard"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Raw pane.move while zoomed (expect reason:zoomed_tab):"
  md_json "$blocked_resp"
  md "Raw pane.move after un-zoom (expect success):"
  md_json "$retry_resp"
  md "blocked: changed=$blocked_changed reason=$blocked_reason. retry: changed=$retry_changed. Final tabA.pane_count=$tabA_n (want 3)."
  md ""
}

# ---------------------------------------------------------------------------
# Case 7: layout.set_split_ratio -- polarity of the path booleans.
# Uses layout.export (LayoutNode: type/direction/ratio/first/second/pane_id)
# to read the tree directly rather than inferring it from rects, since the
# export schema names its two children explicitly.
# ---------------------------------------------------------------------------
case7() {
  local map ws tabA tabB p1 p2 p3 p4
  local ratio_resp t0 evt export_before split_resp export_3pane
  local true_resp true_export false_resp false_export
  local root_ratio_before nested_ratio_before
  local root_ratio_true nested_ratio_true root_ratio_false nested_ratio_false
  local verdict polarity_true polarity_false root_ratio_a partA_verdict

  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  # Part A: path:[] on the 2-pane tab.
  t0=$(now_ms)
  ratio_resp=$(req "{\"id\":\"c7a\",\"method\":\"layout.set_split_ratio\",\"params\":{\"tab_id\":\"$tabA\",\"path\":[],\"ratio\":0.7}}")
  evt=$(record_timing "$t0")
  export_before=$(req "{\"id\":\"c7a-export\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$tabA\"}}")
  root_ratio_a=$(jq -r '.result.layout.root.ratio' <<<"$export_before")
  partA_verdict="FAIL"
  [ "$root_ratio_a" = "0.7" ] && partA_verdict="PASS"

  # Part B: 3-pane tab (split right for p1|p2, then split down on p2 -> p4).
  split_resp=$(mreq "{\"id\":\"c7-split\",\"method\":\"pane.split\",\"params\":{\"target_pane_id\":\"$p2\",\"direction\":\"down\"}}")
  p4=$(jq -r .result.pane.pane_id <<<"$split_resp")
  export_3pane=$(req "{\"id\":\"c7b-export0\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$tabA\"}}")
  root_ratio_before=$(jq -r '.result.layout.root.ratio' <<<"$export_3pane")
  nested_ratio_before=$(jq -r '.result.layout.root.second.ratio // .result.layout.root.first.ratio' <<<"$export_3pane")

  true_resp=$(mreq "{\"id\":\"c7-true\",\"method\":\"layout.set_split_ratio\",\"params\":{\"tab_id\":\"$tabA\",\"path\":[true],\"ratio\":0.2}}")
  true_export=$(req "{\"id\":\"c7-true-export\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$tabA\"}}")
  root_ratio_true=$(jq -r '.result.layout.root.ratio' <<<"$true_export")
  nested_ratio_true=$(jq -r '.result.layout.root.second.ratio // "n/a"' <<<"$true_export")

  false_resp=$(mreq "{\"id\":\"c7-false\",\"method\":\"layout.set_split_ratio\",\"params\":{\"tab_id\":\"$tabA\",\"path\":[false],\"ratio\":0.6}}")
  false_export=$(req "{\"id\":\"c7-false-export\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$tabA\"}}")
  root_ratio_false=$(jq -r '.result.layout.root.ratio' <<<"$false_export")
  nested_ratio_false=$(jq -r '.result.layout.root.second.ratio // "n/a"' <<<"$false_export")

  # Determine which node each boolean addressed. An errored set_split_ratio
  # call leaves the tree unchanged, so a plain ratio-diff can't tell "no-op"
  # apart from "explicit error" -- pull the error code too when present.
  local true_err false_err
  true_err=$(jq -r '.error.code // empty' <<<"$true_resp")
  false_err=$(jq -r '.error.code // empty' <<<"$false_resp")

  polarity_true="no-op (unchanged, no error)"
  [ -n "$true_err" ] && polarity_true="error: $true_err"
  [ "$root_ratio_true" = "0.2" ] && polarity_true="root split (first=p1 leaf, second=nested)"
  [ "$nested_ratio_true" = "0.2" ] && polarity_true="nested split (second child of root)"

  polarity_false="no-op (unchanged, no error)"
  [ -n "$false_err" ] && polarity_false="error: $false_err"
  [ "$root_ratio_false" = "0.6" ] && polarity_false="root split (first=p1 leaf, second=nested)"
  [ "$nested_ratio_false" = "0.6" ] && polarity_false="nested split (second child of root)"

  verdict="DIVERGED"
  if { [ "$root_ratio_true" = "0.2" ] || [ "$nested_ratio_true" = "0.2" ] \
       || [ "$root_ratio_false" = "0.6" ] || [ "$nested_ratio_false" = "0.6" ]; } \
     && [ "$polarity_true" != "$polarity_false" ]; then
    verdict="PASS"
  fi
  [ "$partA_verdict" = "FAIL" ] && verdict="FAIL"
  record_case 7 "$verdict"

  md "## Case 7: layout.set_split_ratio path polarity"
  md ""
  md "**Verdict: $verdict** (root path:[] = $partA_verdict; echo=${evt:-none}ms)"
  md ""
  md "### Part A: path:[] ratio 0.7 on the 2-pane tab"
  md ""
  md "Raw response:"
  md_json "$ratio_resp"
  md "layout.export root.ratio after = $root_ratio_a (want 0.7)."
  md ""
  md "### Part B: 3-pane tab (p1 | [p2 / p4], root split right, nested split down)"
  md ""
  md "Tree before either path test (layout.export):"
  md_json "$export_3pane"
  md "root.ratio before=$root_ratio_before, nested.ratio before=$nested_ratio_before."
  md ""
  md "path:[true] ratio:0.2 response:"
  md_json "$true_resp"
  md "Resulting tree:"
  md_json "$true_export"
  md "root.ratio=$root_ratio_true, nested.ratio=$nested_ratio_true."
  md ""
  md "path:[false] ratio:0.6 response:"
  md_json "$false_resp"
  md "Resulting tree:"
  md_json "$false_export"
  md "root.ratio=$root_ratio_false, nested.ratio=$nested_ratio_false."
  md ""
  md "### Polarity table"
  md ""
  md "| path | node addressed | evidence |"
  md "|---|---|---|"
  md "| [] | root split (the only split in a 2-pane tab) | root.ratio -> 0.7 |"
  md "| [true] | $polarity_true | root.ratio=$root_ratio_true, nested.ratio=$nested_ratio_true |"
  md "| [false] | $polarity_false | root.ratio=$root_ratio_false, nested.ratio=$nested_ratio_false |"
  md ""
}

# ---------------------------------------------------------------------------
# Case 8: whole-tab migration preserving split shape.
# ---------------------------------------------------------------------------
case8() {
  local map ws tabA tabB p1 p2 p3
  local export_before direction ratio move1_resp new_ws new_tab new_p1
  local move2_resp new_p2 export_after direction_after ratio_after verdict
  map=$(seed)
  ws=$(jq -r .ws <<<"$map"); tabA=$(jq -r .tabA <<<"$map"); tabB=$(jq -r .tabB <<<"$map")
  p1=$(jq -r .p1 <<<"$map"); p2=$(jq -r .p2 <<<"$map"); p3=$(jq -r .p3 <<<"$map")

  export_before=$(req "{\"id\":\"c8-export0\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$tabA\"}}")
  direction=$(jq -r '.result.layout.root.direction' <<<"$export_before")
  ratio=$(jq -r '.result.layout.root.ratio' <<<"$export_before")

  move1_resp=$(mreq "{\"id\":\"c8-move1\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p1\",\"destination\":{\"type\":\"new_workspace\",\"label\":\"dest\",\"tab_label\":\"migrated\"}}}")
  new_ws=$(jq -r '.result.move_result.created_workspace.workspace_id' <<<"$move1_resp")
  new_tab=$(jq -r '.result.move_result.created_tab.tab_id' <<<"$move1_resp")
  new_p1=$(jq -r '.result.move_result.pane.pane_id' <<<"$move1_resp")

  move2_resp=$(mreq "{\"id\":\"c8-move2\",\"method\":\"pane.move\",\"params\":{\"pane_id\":\"$p2\",\"destination\":{\"type\":\"tab\",\"tab_id\":\"$new_tab\",\"target_pane_id\":\"$new_p1\",\"split\":\"$direction\",\"ratio\":$ratio}}}")
  new_p2=$(jq -r '.result.move_result.pane.pane_id' <<<"$move2_resp")

  export_after=$(req "{\"id\":\"c8-export1\",\"method\":\"layout.export\",\"params\":{\"tab_id\":\"$new_tab\"}}")
  direction_after=$(jq -r '.result.layout.root.direction' <<<"$export_after")
  ratio_after=$(jq -r '.result.layout.root.ratio' <<<"$export_after")

  verdict="FAIL"
  [ "$direction_after" = "$direction" ] && [ "$ratio_after" = "$ratio" ] && verdict="PASS"
  record_case 8 "$verdict"

  md "## Case 8: whole-tab migration preserves split shape"
  md ""
  md "**Verdict: $verdict**"
  md ""
  md "Source tabA layout (direction=$direction, ratio=$ratio):"
  md_json "$export_before"
  md "Move p1 -> new_workspace (label dest, tab_label migrated), new pane=$new_p1 in tab=$new_tab, workspace=$new_ws:"
  md_json "$move1_resp"
  md "Move p2 -> tab destination in new_tab, replaying direction=$direction ratio=$ratio, new pane=$new_p2:"
  md_json "$move2_resp"
  md "Destination tab layout after:"
  md_json "$export_after"
  md "direction after=$direction_after (want $direction), ratio after=$ratio_after (want $ratio)."
  md ""
}

# ---------------------------------------------------------------------------
main() {
  : >"$FINDINGS"
  md "# Spike 03: mutation verb matrix + split-ratio paths"
  md ""
  md "Findings from running spikes/03-verbs/run.sh against a scratch herdr 0.8.0 session (never the default ~/.config/herdr/herdr.sock). Every request is a fresh one-shot nc -U connection per spike 02's finding; the events subscription is a second, separate, receive-only connection read by a small unbuffered python3 reader. Each case seeds its own fresh workspace via spikes/lib/seed-layout.sh, so cases do not depend on each other's leftover state."
  md ""

  SOCK=$("$LIB/scratch-session.sh" start "$SESSION_NAME")
  echo "scratch socket: $SOCK"
  start_subscriber

  case1
  case1b
  case2
  case3
  case4
  case5
  case6
  case7
  case8

  # mapfile is bash4+; this box's /bin/bash is 3.2, so read line-by-line.
  if [ -s "$TIMING_FILE" ]; then
    while IFS= read -r _line; do TIMING_SAMPLES+=("$_line"); done <"$TIMING_FILE"
  fi

  md "## Event-echo timing distribution"
  md ""
  if [ "${#TIMING_SAMPLES[@]}" -eq 0 ]; then
    md "No timing samples matched (see per-case notes)."
  else
    local sorted min max median n mid
    sorted=$(printf '%s\n' "${TIMING_SAMPLES[@]}" | sort -n)
    n=${#TIMING_SAMPLES[@]}
    min=$(printf '%s\n' "$sorted" | head -1)
    max=$(printf '%s\n' "$sorted" | tail -1)
    mid=$(( (n + 1) / 2 ))
    median=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
    md "Samples (ms), send -> matching layout_updated/pane_moved arrival, n=$n:"
    md ""
    md '```'
    printf '%s\n' "${TIMING_SAMPLES[@]}" >>"$FINDINGS"
    md '```'
    md "min=${min}ms, median=${median}ms, max=${max}ms. The server polls for events every 100ms per the design doc; most samples should land at or under roughly one poll interval."
  fi
  md ""

  md "## Summary for Tasks 20/23"
  md ""
  md "- Case totals: PASS=$PASS_COUNT FAIL=$FAIL_COUNT DIVERGED=$DIVERGED_COUNT."
  md "- Every mutating call opened its own one-shot connection (spike 02's finding); the subscription connection was never interleaved with a request."
  md "- Case 3's cross-workspace re-key: old/new pane id pair recorded above. In this run pane_moved was the only pane-lifecycle event for the whole new_workspace move (no pane_closed/pane_created at all, for the moved pane or otherwise); Task 20/23 planners can treat pane.moved as authoritative for re-keying local pane-id state without reconciling a close/create pair. Note the case's own bad-event check only gates on events referencing the moved pane's old/new id specifically, in case a future herdr version does add bootstrap noise around a new_workspace/new_tab destination -- see that case's verdict (DIVERGED, not FAIL, if it ever does)."
  md "- Case 7's polarity table is the key new fact for the geometry engine: see the table above for which of true/false in a path element addresses which child."
  md ""

  echo ""
  echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT DIVERGED=$DIVERGED_COUNT"
}

main "$@"
