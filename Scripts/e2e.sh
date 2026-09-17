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
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paddock-e2e-XXXXXX")"
PORT_FILE="$WORK_DIR/bridge.port"
BRIDGE_PID=""
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

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  # Before the session stop, never after: the bridge's control verbs start a
  # server back up, and one in flight would undo the teardown.
  if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
  if [ -n "$SESSION_STARTED" ]; then
    "$LIB/scratch-session.sh" stop "$SESSION_NAME" >/dev/null 2>&1 || true
    if [ -S "$HOME/.config/herdr/sessions/paddock-$SESSION_NAME/herdr.sock" ]; then
      echo "e2e.sh: WARNING: scratch server still bound at paddock-$SESSION_NAME" >&2
    fi
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

SOCKET=$("$LIB/scratch-session.sh" start "$SESSION_NAME")
SESSION_STARTED=1
SEED_IDS=$("$LIB/seed-layout.sh" "$SOCKET" | jq -c .)

# One session serves the whole `xcodebuild test` invocation, so the bridge's
# reseed-session verb is how a case that changed the layout hands the next one
# a clean world. Dropping the session directory resets herdr's own numbering,
# which is what keeps the seed ids stable across a reseed.
python3 "$LIB/e2e-bridge.py" \
  --socket "$SOCKET" --lib "$LIB" --session "$SESSION_NAME" \
  --herdr-bin "$herdr_bin" --port-file "$PORT_FILE" &
BRIDGE_PID=$!

for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
BRIDGE_PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
[ -n "$BRIDGE_PORT" ] || { echo "e2e.sh: the bridge never reported a port" >&2; exit 1; }

export TEST_RUNNER_PADDOCK_SOCKET="$SOCKET"
export TEST_RUNNER_PADDOCK_SEED_IDS="$SEED_IDS"
export TEST_RUNNER_PADDOCK_BRIDGE_PORT="$BRIDGE_PORT"
export TEST_RUNNER_PADDOCK_HERDR_BIN="$herdr_bin"
if [ -n "${PADDOCK_RESNAPSHOT_SECONDS:-}" ]; then
  export TEST_RUNNER_PADDOCK_RESNAPSHOT_SECONDS="$PADDOCK_RESNAPSHOT_SECONDS"
fi

echo "e2e.sh: session paddock-$SESSION_NAME"
echo "e2e.sh: socket $SOCKET"
echo "e2e.sh: seed $SEED_IDS"
echo "e2e.sh: bridge 127.0.0.1:$BRIDGE_PORT"

only_testing=("-only-testing:PaddockUITests")
if [ "$#" -gt 0 ]; then only_testing=("$@"); fi

xcodebuild -scheme Paddock -configuration Debug -skipPackagePluginValidation \
  -destination 'platform=macOS' test "${only_testing[@]}"
