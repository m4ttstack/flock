#!/usr/bin/env bash
# Runs the "scale" probe (spawns N observe children + SwiftTerm Terminals)
# and samples ps for the swift process + all observe children every 10s
# over a 60s window, then prints a CSV of the samples and kills everything.
set -euo pipefail
sock="${1:?socket path}"
outdir="${2:?outdir}"
panes_csv="${3:?comma-separated pane ids}"
# Split explicitly rather than relying on the caller shell's word-splitting
# (zsh does not word-split unquoted variables the way bash does).
IFS=',' read -r -a panes <<< "$panes_csv"

bin="$(cd "$(dirname "$0")" && pwd)/.build/release/PaddockObserveSpike"
mkdir -p "$outdir"
log="$outdir/scale-${#panes[@]}.log"
csv="$outdir/scale-${#panes[@]}.csv"

"$bin" scale "$sock" 75 "${panes[@]}" > "$log" 2>&1 &
driver_pid=$!

# Wait for all children to report started.
for _ in $(seq 1 50); do
  grep -q '"all_started"' "$log" && break
  sleep 0.2
done

self_pid=$(grep -o '"self_pid","pid":[0-9]*' "$log" | grep -o '[0-9]*$' || true)
child_pids=$(grep -o '"child_pid".*"pid":[0-9]*' "$log" | grep -o '[0-9]*$' || true)
all_pids="$self_pid $child_pids"
pid_args=()
for p in $all_pids; do pid_args+=(-p "$p"); done

echo "sample_t,pid,pcpu,rss_kb" > "$csv"
start=$(date +%s)
for i in $(seq 1 6); do
  now=$(date +%s)
  elapsed=$((now - start))
  ps -o pid=,%cpu=,rss= "${pid_args[@]}" 2>/dev/null | while read -r pid pcpu rss; do
    echo "$elapsed,$pid,$pcpu,$rss" >> "$csv"
  done
  sleep 10
done

kill "$driver_pid" 2>/dev/null || true
wait "$driver_pid" 2>/dev/null || true
for p in $child_pids; do
  kill "$p" 2>/dev/null || true
done

echo "wrote $csv"
