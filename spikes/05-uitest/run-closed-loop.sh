#!/usr/bin/env bash
# Runs ClosedLoopUITests with its scratch herdr session started and seeded
# HERE, in plain unsandboxed bash -- see FINDINGS.md "sandboxed test runner":
# the macOS UI test runner cannot bind/listen a socket outside its own
# container, so the server must exist before xcodebuild ever launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/spikes/lib"
HERE="$ROOT/spikes/05-uitest"
SESSION_NAME="closedloop-$$"

cleanup() {
  "$LIB/scratch-session.sh" stop "$SESSION_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

SOCK=$("$LIB/scratch-session.sh" start "$SESSION_NAME")
MAP=$("$LIB/seed-layout.sh" "$SOCK")
WS=$(jq -r .ws <<<"$MAP")
P1=$(jq -r .p1 <<<"$MAP")

echo "scratch socket: $SOCK"
echo "seed ids: ws=$WS p1=$P1"

cd "$HERE"
# A plain `export` of an arbitrary name does NOT reach the XCTestCase:
# xcodebuild curates the whole environment for the sandboxed test-runner
# process, not just PATH/HOME (see FINDINGS.md). TEST_RUNNER_<NAME> is
# Apple's documented escape hatch, but it only takes effect as an exported
# environment variable in xcodebuild's OWN process environment -- passing
# it as a trailing KEY=VALUE argument is parsed as a build-setting override
# instead and never reaches the test host.
export TEST_RUNNER_SPIKE_SCRATCH_SOCKET="$SOCK"
export TEST_RUNNER_SPIKE_WS_ID="$WS"
export TEST_RUNNER_SPIKE_P1_ID="$P1"
export TEST_RUNNER_SPIKE_SESSION_NAME="$SESSION_NAME"

xcodebuild -project SpikeUITest.xcodeproj -scheme SpikeApp test \
  -destination 'platform=macOS' \
  -only-testing:SpikeUITests/ClosedLoopUITests
