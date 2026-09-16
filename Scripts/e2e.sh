#!/usr/bin/env bash
# Runs the PaddockUITests suite against a herdr session created for this run
# and destroyed with it.
#
# The split between this script and the test bundle is not a style choice:
# Xcode wraps every macOS UI-testing bundle in a `-Runner.app` that is App
# Sandboxed unconditionally, and that sandbox cannot bind a listening socket,
# so `herdr server` has to already exist before xcodebuild launches anything
# (spikes/05-uitest/FINDINGS.md). Everything the runner needs to know reaches
# it through `TEST_RUNNER_`-prefixed variables exported here: xcodebuild
# strips the prefix and injects the rest into the test host's environment,
# and it is the only channel that works -- a plain export never arrives, and
# a trailing KEY=VALUE argument is parsed as a build-setting override.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
LIB="$ROOT/Tests/PaddockUITests/Support/bin"

SESSION_NAME="e2e-$$"
CONTROL_SOCKET="${TMPDIR:-/tmp}/paddock-e2e-$$.ctl"
CONTROL_PID=""
SESSION_STARTED=""

for tool in jq nc xcodegen xcodebuild; do
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
  # Before the session stop, never after: the control loop's whole job is to
  # start a server back up, and it would happily undo the teardown.
  if [ -n "$CONTROL_PID" ]; then
    kill "$CONTROL_PID" 2>/dev/null || true
    wait "$CONTROL_PID" 2>/dev/null || true
  fi
  pkill -f -- "-lU $CONTROL_SOCKET" 2>/dev/null || true
  rm -f "$CONTROL_SOCKET"
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

# The runner cannot write outside its container, so the only signal it can
# raise is a connection: a one-shot listener per request, re-armed each time.
# Requests are fire-and-forget; the caller watches the herdr socket itself for
# the server coming back, which is the readiness the caller actually wants.
control_loop() {
  while :; do
    rm -f "$CONTROL_SOCKET"
    request="$(nc -lU "$CONTROL_SOCKET" 2>/dev/null || true)"
    case "$request" in
      restart-server) "$LIB/scratch-session.sh" restart "$SESSION_NAME" >/dev/null 2>&1 || true ;;
      *) sleep 0.2 ;;
    esac
  done
}
control_loop &
CONTROL_PID=$!

export TEST_RUNNER_PADDOCK_SOCKET="$SOCKET"
export TEST_RUNNER_PADDOCK_SEED_IDS="$SEED_IDS"
export TEST_RUNNER_PADDOCK_CONTROL_SOCKET="$CONTROL_SOCKET"
export TEST_RUNNER_PADDOCK_HERDR_BIN="$herdr_bin"
if [ -n "${PADDOCK_RESNAPSHOT_SECONDS:-}" ]; then
  export TEST_RUNNER_PADDOCK_RESNAPSHOT_SECONDS="$PADDOCK_RESNAPSHOT_SECONDS"
fi

echo "e2e.sh: session paddock-$SESSION_NAME"
echo "e2e.sh: socket $SOCKET"
echo "e2e.sh: seed $SEED_IDS"

only_testing=("-only-testing:PaddockUITests")
if [ "$#" -gt 0 ]; then only_testing=("$@"); fi

xcodebuild -scheme Paddock -configuration Debug -skipPackagePluginValidation \
  -destination 'platform=macOS' test "${only_testing[@]}"
