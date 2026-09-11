#!/usr/bin/env bash
# Scratch herdr servers only: never touches the default session.
set -euo pipefail
cmd="$1"; name="paddock-${2:?session name}"
sock="$HOME/.config/herdr/sessions/$name/herdr.sock"
case "$cmd" in
  start)
    herdr --session "$name" server >/dev/null 2>&1 &
    for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
    [ -S "$sock" ] || { echo "server did not bind $sock" >&2; exit 1; }
    echo "$sock" ;;
  stop)
    HERDR_SOCKET_PATH="$sock" herdr server stop || true
    rm -rf "$HOME/.config/herdr/sessions/$name" ;;
  *)
    echo "usage: scratch-session.sh {start|stop} <name>" >&2
    exit 1 ;;
esac
