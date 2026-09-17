#!/usr/bin/env bash
# Scratch herdr servers only. Every path here is derived from a session name,
# so the default session's socket ($HOME/.config/herdr/herdr.sock) is
# unreachable by construction and refused again below.
set -euo pipefail

usage() {
  echo "usage: scratch-session.sh {start|restart|stop} <name>" >&2
  exit 1
}

cmd="${1:-}"; [ -n "$cmd" ] || usage
raw_name="${2:-}"; [ -n "$raw_name" ] || usage
# `stop` ends in `rm -rf` on a path built from this name, and a name carrying a
# separator or a dot segment escapes the sessions directory entirely, where the
# default-socket compare below would never fire.
case "$raw_name" in
  */*|.*)
    echo "refusing a session name that is not a single plain segment: $raw_name" >&2
    exit 1 ;;
esac
name="flock-$raw_name"

config_dir="$HOME/.config/herdr"
session_dir="$config_dir/sessions/$name"
sock="$session_dir/herdr.sock"
pidfile="$session_dir/scratch-server.pid"

if [ "$sock" = "$config_dir/herdr.sock" ]; then
  echo "refusing to act on the default herdr socket" >&2
  exit 1
fi

# HERDR_BIN when set, else `herdr` on PATH: the same order
# ControlBridge.resolveHerdrBinary applies, so one env var points the whole
# harness at a patched build.
herdr_bin="${HERDR_BIN:-herdr}"

start_server() {
  mkdir -p "$session_dir"
  "$herdr_bin" --session "$name" server >/dev/null 2>&1 &
  echo $! > "$pidfile"
  for _ in $(seq 1 100); do [ -S "$sock" ] && return 0; sleep 0.1; done
  echo "server did not bind $sock" >&2
  return 1
}

stop_server() {
  # Guarded on the socket existing: without it `herdr server stop` would fall
  # back to resolving a socket of its own, which is the default session's.
  if [ -S "$sock" ]; then
    HERDR_SOCKET_PATH="$sock" "$herdr_bin" server stop >/dev/null 2>&1 || true
  fi
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    comm="$(ps -p "${pid:-0}" -o comm= 2>/dev/null || true)"
    # A recorded pid outlives the process it named and the number gets reused,
    # so the command is checked before the signal: the patched build is named
    # herdr-mouse-cli, which this matches too.
    case "$comm" in
      *herdr*)
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$pid" 2>/dev/null || true ;;
    esac
    rm -f "$pidfile"
  fi
  for _ in $(seq 1 50); do [ -S "$sock" ] || break; sleep 0.1; done
  rm -f "$sock"
}

case "$cmd" in
  start)
    start_server
    echo "$sock" ;;
  restart)
    # Keeps $session_dir, so the server comes back up on the state it left
    # behind rather than on an empty session.
    stop_server
    start_server
    echo "$sock" ;;
  stop)
    stop_server
    rm -rf "$session_dir" ;;
  *)
    usage ;;
esac
