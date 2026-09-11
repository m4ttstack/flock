#!/bin/bash
# Stand-in for `herdr terminal session observe <pane> --cols C --rows R`.
set -euo pipefail

cols=""
rows=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cols) cols="$2"; shift 2 ;;
    --rows) rows="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "${FAKE_OBSERVE_PID_FILE:-}" ]]; then
  echo "$$" >"${FAKE_OBSERVE_PID_FILE}"
fi

if [[ "${FAKE_OBSERVE_CONTINUOUS:-0}" == "1" ]]; then
  # Reattach-race test variant: emit frames continuously, tagging each one
  # with this invocation's own --cols/--rows so the test can tell an OLD
  # spawn's frames apart from a NEW one's after a mid-stream reattach.
  seq=0
  while true; do
    seq=$((seq + 1))
    printf '{"type":"terminal.frame","seq":%d,"encoding":"ansi","width":%s,"height":%s,"full":false,"bytes":""}\n' \
      "$seq" "$cols" "$rows"
    sleep 0.005
  done
fi

fixture="${FAKE_OBSERVE_FIXTURE:?FAKE_OBSERVE_FIXTURE must point at observe.ndjson}"
head -n 3 "${fixture}"

if [[ "${FAKE_OBSERVE_HANG:-0}" == "1" ]]; then
  # Detach/kill test variant: stay alive with no terminal.closed so the
  # supervisor has a live child to terminate.
  exec sleep 999999
fi

echo '{"type":"terminal.closed"}'
