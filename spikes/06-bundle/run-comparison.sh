#!/usr/bin/env bash
# Drives the three helper-launch paths against the signed nest, once clean
# and once with the quarantine xattr applied (simulating a downloaded
# install), and records marker-file evidence for each. Writes a plain-text
# log to build/comparison.log; FINDINGS.md is written by hand from this.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
HOST_APP="$BUILD/SpikeHost.app"
HOST_BIN="$HOST_APP/Contents/MacOS/SpikeHost"
RESULT_DIR=/tmp/paddock-spike-06
LOG="$BUILD/comparison.log"

: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

reset_markers() { rm -rf "$RESULT_DIR"; mkdir -p "$RESULT_DIR"; }

kill_helpers() {
    pkill -f "SpikeHelper.app/Contents/MacOS/SpikeHelper" >/dev/null 2>&1 || true
    sleep 0.3
}

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

echo "Comparison run started $(date)" | tee "$LOG"

say ""
say "############################################################"
say "# Pass 1: clean (no quarantine)"
say "############################################################"
run_state "clean"

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

say ""
say "=== spctl -a -vv, quarantined state ==="
spctl -a -vv "$HOST_APP" 2>&1 | tee -a "$LOG"
spctl -a -vv "$HOST_APP/Contents/Helpers/SpikeHelper.app" 2>&1 | tee -a "$LOG"

say ""
say "Comparison run finished $(date)"
