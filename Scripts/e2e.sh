#!/usr/bin/env bash
# Runs the PaddockUITests suite against a herdr session created for this run
# and destroyed with it.
#
# The split between this script and the test bundle is not a style choice:
# Xcode wraps every macOS UI-testing bundle in a `-Runner.app` that is App
# Sandboxed unconditionally, and that sandbox neither binds a listening socket
# nor connects to a unix socket outside its container, so the bundle can
# neither start herdr nor talk to it. `e2e-bridge.py` is what closes that gap;
# the sandbox does permit outbound TCP to loopback.
#
# Everything the runner needs to know reaches it through `TEST_RUNNER_`-prefixed
# variables exported here: xcodebuild strips the prefix and injects the rest
# into the test host's environment, and it is the only channel that works -- a
# plain export never arrives, and a trailing KEY=VALUE argument is parsed as a
# build-setting override.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
LIB="$ROOT/Tests/PaddockUITests/Support/bin"

SESSION_NAME="e2e-$$"
SESSION_DIR="$HOME/.config/herdr/sessions/paddock-$SESSION_NAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paddock-e2e-XXXXXX")"
PORT_FILE="$WORK_DIR/bridge.port"
BRIDGE_PID=""
TEST_PID=""
SESSION_STARTED=""

for tool in jq nc python3 xcodegen xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "e2e.sh: $tool is required" >&2; exit 1; }
done

# PADDOCK_HERDR_BIN is the app's own override, so honoring it first keeps the
# server, the seed and the pane bridges on one binary. The patched build is
# the default when it is installed, because that is what paddock runs against.
herdr_bin="${PADDOCK_HERDR_BIN:-${HERDR_BIN:-}}"
if [ -z "$herdr_bin" ]; then
  patched="$HOME/.local/share/paddock/herdr-mouse-cli"
  if [ -x "$patched" ]; then herdr_bin="$patched"; else herdr_bin="$(command -v herdr || true)"; fi
fi
[ -x "$herdr_bin" ] || { echo "e2e.sh: no herdr binary (set PADDOCK_HERDR_BIN)" >&2; exit 1; }
export HERDR_BIN="$herdr_bin"

# Every process this run starts carries the run's own session name, in its argv
# or in its environment: the herdr server and the terminals it spawns, the
# bridge, the test runner, and the app under test. Matching on that name is
# what makes a sweep safe -- matching on `Paddock.app` would also match the
# instance Matt runs from the same DerivedData build.
sweep_run_processes() {
  local signal="$1" snapshot pids pid
  # Taken before the pipeline that filters it, so the snapshot cannot contain
  # that grep. It does contain the `ps` subshell, which inherits this shell's
  # environment and so the session name; that pid is already dead by the time
  # the loop reaches it, which is one of the things the `|| true` absorbs.
  # This shell is excluded by pid for the same reason.
  snapshot=$(ps -xE -o pid=,command= 2>/dev/null || true)
  # The session name ends in this shell's pid, and a pid is a prefix of longer
  # pids, so an unanchored match would let a run whose name is `e2e-123` sweep
  # away a concurrent `e2e-1234`. Requiring a non-digit (or end of line) after
  # the name is the boundary; the name itself is only `e2e-` and digits, so it
  # carries no regex metacharacters. Anchoring on the socket path instead would
  # miss the herdr server, whose argv names the session without a trailing
  # separator.
  pids=$(printf '%s\n' "$snapshot" \
    | grep -E "paddock-$SESSION_NAME([^0-9]|$)" \
    | awk -v self="$$" '$1 ~ /^[0-9]+$/ && $1 != self { print $1 }')
  for pid in $pids; do
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  # The test run goes first: it is what holds the session open, and it would
  # keep driving a bridge and a server being torn down underneath it.
  if [ -n "$TEST_PID" ]; then
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  # Before the session stop, never after: the bridge's control verbs start a
  # server back up, and one in flight would undo the teardown.
  if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  # Killing xcodebuild reaches neither the test runner nor the app it launched:
  # this script has no job control, so there is no process group to signal, and
  # the bundle's own teardown block never runs when the test process dies
  # mid-case. An app left behind would go on writing the window-frame default
  # the real Paddock reads, pointed at a socket this function is about to
  # destroy.
  sweep_run_processes TERM
  sleep 1
  rm -rf "$WORK_DIR"
  if [ -n "$SESSION_STARTED" ]; then
    "$LIB/scratch-session.sh" stop "$SESSION_NAME" >/dev/null 2>&1 || true
    sweep_run_processes KILL
    # A reseed the bridge was midway through spawns its own `start`, which
    # outlives the bridge and can bind a server after the stop above ran.
    if [ -S "$SESSION_DIR/herdr.sock" ]; then
      "$LIB/scratch-session.sh" stop "$SESSION_NAME" >/dev/null 2>&1 || true
    fi
    if [ -S "$SESSION_DIR/herdr.sock" ]; then
      echo "e2e.sh: WARNING: scratch server still bound at paddock-$SESSION_NAME" >&2
    fi
  else
    sweep_run_processes KILL
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# Compiled before the session exists so a cold build does not run the scratch
# server's clock; the `test` invocation below re-checks and finds it current.
Scripts/libghostty.sh --check
xcodegen
xcodebuild -scheme Paddock -configuration Debug -skipPackagePluginValidation \
  -destination 'platform=macOS' build-for-testing

# Armed before the start, not after: `start` spawns the server and only then
# waits for it to bind, so a bind that times out has still left a process and a
# session directory for the teardown to clear.
SESSION_STARTED=1
SOCKET=$("$LIB/scratch-session.sh" start "$SESSION_NAME")
SEED_IDS=$("$LIB/seed-layout.sh" "$SOCKET" | jq -c .)

# One session serves the whole `xcodebuild test` invocation, so the bridge's
# reseed-session verb is how a case that changed the layout hands the next one
# a clean world. Dropping the session directory resets herdr's own numbering,
# which is what keeps the seed ids stable across a reseed.
python3 "$LIB/e2e-bridge.py" \
  --socket "$SOCKET" --lib "$LIB" --session "$SESSION_NAME" \
  --herdr-bin "$herdr_bin" --port-file "$PORT_FILE" --parent-pid "$$" &
BRIDGE_PID=$!

for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
BRIDGE_PORT=""
BRIDGE_TOKEN=""
read -r BRIDGE_PORT BRIDGE_TOKEN < "$PORT_FILE" 2>/dev/null || true
[ -n "$BRIDGE_PORT" ] && [ -n "$BRIDGE_TOKEN" ] || {
  echo "e2e.sh: the bridge never reported a port and token" >&2; exit 1
}

export TEST_RUNNER_PADDOCK_SOCKET="$SOCKET"
export TEST_RUNNER_PADDOCK_SEED_IDS="$SEED_IDS"
export TEST_RUNNER_PADDOCK_BRIDGE_PORT="$BRIDGE_PORT"
export TEST_RUNNER_PADDOCK_BRIDGE_TOKEN="$BRIDGE_TOKEN"
export TEST_RUNNER_PADDOCK_HERDR_BIN="$herdr_bin"
# The product's re-snapshot backstop is minutes wide, which no case can wait
# out, so the suite runs with a short one unless the caller names its own.
export TEST_RUNNER_PADDOCK_RESNAPSHOT_SECONDS="${PADDOCK_RESNAPSHOT_SECONDS:-2}"

echo "e2e.sh: session paddock-$SESSION_NAME"
echo "e2e.sh: socket $SOCKET"
echo "e2e.sh: herdr $herdr_bin"
echo "e2e.sh: seed $SEED_IDS"
echo "e2e.sh: bridge 127.0.0.1:$BRIDGE_PORT"
echo "e2e.sh: resnapshot ${TEST_RUNNER_PADDOCK_RESNAPSHOT_SECONDS}s"

only_testing=("-only-testing:PaddockUITests")
if [ "$#" -gt 0 ]; then only_testing=("$@"); fi

# Backgrounded and waited on rather than run in the foreground: a
# non-interactive bash defers a trap until its foreground command returns, so
# a signal sent to this script alone would sit unhandled for the length of the
# test run. `wait` is interruptible, so the teardown runs when the signal
# arrives whether or not the signal also reached xcodebuild.
xcodebuild -scheme Paddock -configuration Debug -skipPackagePluginValidation \
  -destination 'platform=macOS' test "${only_testing[@]}" &
TEST_PID=$!
set +e
wait "$TEST_PID"
TEST_STATUS=$?
set -e
TEST_PID=""
exit "$TEST_STATUS"
