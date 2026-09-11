#!/bin/bash
# Stand-in for `herdr terminal session observe <pane> --cols C --rows R`.
# Argv is accepted but unparsed: nothing here depends on pane/cols/rows.
set -euo pipefail

if [[ -n "${FAKE_OBSERVE_PID_FILE:-}" ]]; then
  echo "$$" >"${FAKE_OBSERVE_PID_FILE}"
fi

fixture="${FAKE_OBSERVE_FIXTURE:?FAKE_OBSERVE_FIXTURE must point at observe.ndjson}"
head -n 3 "${fixture}"

if [[ "${FAKE_OBSERVE_HANG:-0}" == "1" ]]; then
  # Detach/kill test variant: stay alive with no terminal.closed so the
  # supervisor has a live child to terminate.
  exec sleep 999999
fi

echo '{"type":"terminal.closed"}'
