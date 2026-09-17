#!/usr/bin/env bash
# Drives the three helper-launch paths against the signed nest, once clean
# and once with the quarantine xattr applied (simulating a downloaded
# install), and records marker-file evidence for each. Also scripts three
# checks that a prior pass of this spike only ran by hand: the
# Contents/Helpers-only SMAppService registration failure, spctl -a -vv in
# BOTH clean and quarantined states, and a plain `open` launch of the
# quarantined host. Writes a plain-text log to build/comparison.log;
# FINDINGS.md cites this log's evidence.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
HOST_APP="$BUILD/SpikeHost.app"
HOST_BIN="$HOST_APP/Contents/MacOS/SpikeHost"
SIGN_ID="Developer ID Application: Matthew Goodwin (5BF66B3X4V)"
RESULT_DIR=/tmp/flock-spike-06
LOG="$BUILD/comparison.log"

: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

reset_markers() { rm -rf "$RESULT_DIR"; mkdir -p "$RESULT_DIR"; }

kill_helpers() {
    pkill -f "SpikeHelper.app/Contents/MacOS/SpikeHelper" >/dev/null 2>&1 || true
    sleep 0.3
}

# Best-effort unregister so an interrupted run never leaves the login item
# registered. Safe to call when nothing is registered (SMAppService just
# reports "not found"-ish errors, which this script does not treat as fatal).
unregister_login_item() {
    [ -x "$HOST_BIN" ] && "$HOST_BIN" smappservice-unregister >/dev/null 2>&1
    return 0
}

cleanup() {
    kill_helpers
    unregister_login_item
}
trap cleanup EXIT INT

dump_markers() {
    if compgen -G "$RESULT_DIR/*" > /dev/null; then
        for f in "$RESULT_DIR"/*; do
            say "  -- $(basename "$f") --"
            sed 's/^/     /' "$f" | tee -a "$LOG"
        done
    else
        say "  (no marker/result files)"
    fi
}

run_path() {
    local label="$1"; shift
    say ""
    say "=== $label ($HOST_BIN $* ) ==="
    reset_markers
    "$HOST_BIN" "$@" > "$BUILD/last-stdout.txt" 2>"$BUILD/last-stderr.txt"
    local rc=$?
    say "exit code: $rc"
    if [ -s "$BUILD/last-stderr.txt" ]; then
        say "  stderr: $(cat "$BUILD/last-stderr.txt")"
    fi
    sleep 1.5
    dump_markers
    kill_helpers
}

run_state() {
    local state_label="$1"
    say ""
    say "########## STATE: $state_label ##########"

    run_path "(a) NSWorkspace.openApplication [$state_label]" nsworkspace
    run_path "(c) Process exec [$state_label]" process

    say ""
    say "=== (b) SMAppService register [$state_label] ==="
    reset_markers
    "$HOST_BIN" smappservice-register > "$BUILD/last-stdout.txt" 2>"$BUILD/last-stderr.txt"
    say "exit code: $?"
    [ -s "$BUILD/last-stderr.txt" ] && say "  stderr: $(cat "$BUILD/last-stderr.txt")"
    sleep 2
    say "  status after register:"
    "$HOST_BIN" smappservice-status > /dev/null 2>&1
    dump_markers

    say "  unregistering (cleanup, not left behind):"
    "$HOST_BIN" smappservice-unregister > "$BUILD/last-stdout.txt" 2>"$BUILD/last-stderr.txt"
    dump_markers
    kill_helpers
}

# Scripted repro of the "Contents/Helpers-only" SMAppService failure: a
# scratch copy of the already-signed host with the Library/LoginItems copy
# removed, re-signed (outer bundle only -- the untouched Contents/Helpers
# copy keeps its own valid signature), then a register attempt against it.
run_helpers_only_smappservice_check() {
    local variant="$BUILD/SpikeHost-helpers-only.app"
    say ""
    say "=== (b) SMAppService register against a Contents/Helpers-ONLY variant (expect failure) ==="
    rm -rf "$variant"
    cp -R "$HOST_APP" "$variant"
    rm -rf "$variant/Contents/Library/LoginItems/SpikeHelper.app"
    codesign --force --options runtime --sign "$SIGN_ID" "$variant" > /dev/null 2>&1
    reset_markers
    "$variant/Contents/MacOS/SpikeHost" smappservice-register \
        > "$BUILD/last-stdout.txt" 2>"$BUILD/last-stderr.txt"
    say "exit code: $?"
    dump_markers
    # Defensive: register is expected to fail, so there is nothing to
    # unregister, but attempt it anyway in case the identifier partially
    # registered before erroring.
    "$variant/Contents/MacOS/SpikeHost" smappservice-unregister >/dev/null 2>&1
    rm -rf "$variant"
}

run_spctl_check() {
    local state_label="$1"
    say ""
    say "=== spctl -a -vv, $state_label state ==="
    spctl -a -vv "$HOST_APP" 2>&1 | tee -a "$LOG"
    spctl -a -vv "$HOST_APP/Contents/Helpers/SpikeHelper.app" 2>&1 | tee -a "$LOG"
}

# Plain `open` (the Finder-equivalent LaunchServices path) on the quarantined
# host itself, not just the inner NSWorkspace call -- proves (or disproves)
# a block at the outermost, most realistic "user double-clicks the download"
# entry point. `open` returns before the app finishes launching, so poll for
# the marker/result file rather than assuming a fixed delay.
run_open_quarantined_host_check() {
    say ""
    say "=== plain \`open\` of the quarantined host (noop action) ==="
    reset_markers
    open "$HOST_APP" --args noop
    local waited=0
    while [ ! -f "$RESULT_DIR/result-noop.json" ] && [ "$waited" -lt 10 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    dump_markers
    kill_helpers
}

echo "Comparison run started $(date)" | tee "$LOG"

say ""
say "############################################################"
say "# Pass 1: clean (no quarantine)"
say "############################################################"
run_state "clean"
run_spctl_check "clean"
run_helpers_only_smappservice_check

say ""
say "############################################################"
say "# Pass 2: quarantined (recursive xattr, simulates a downloaded/unzipped install)"
say "############################################################"
# Real downloads get com.apple.quarantine on every extracted file, not just
# the top-level bundle dir, so apply it recursively to match that. Flag value
# "02c1" is copied verbatim from a real .app bundle downloaded and never
# opened on this machine (~/Downloads), not invented -- an earlier pass used
# a guessed flag ("0081", the value common in tutorials) that turned out to
# be the flag real browsers use for inert data files (images), not the flag
# used for an actual .app/.dmg download; using the wrong flag would have
# quietly tested the wrong Gatekeeper code path. See FINDINGS.md.
find "$HOST_APP" -exec xattr -w com.apple.quarantine "02c1;00000000;Arc;00000000-0000-0000-0000-000000000000" {} \;
say "quarantine attrs applied. Sample check:"
xattr -p com.apple.quarantine "$HOST_APP" | tee -a "$LOG"
xattr -p com.apple.quarantine "$HOST_APP/Contents/Helpers/SpikeHelper.app" | tee -a "$LOG"

run_state "quarantined"
run_spctl_check "quarantined"
run_open_quarantined_host_check

say ""
say "Comparison run finished $(date)"
