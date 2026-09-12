#!/usr/bin/env python3
"""Throwaway probe: herdr control-transport semantics (task 18d).

Spawns `herdr terminal session control|observe|attach` as subprocesses
against a scratch session and exercises the NDJSON control protocol
directly (no ghostty bridge). Only findings.md survives this spike.
"""
import base64
import json
import os
import subprocess
import sys
import time

HERDR = "herdr"


def env_for(sock):
    e = dict(os.environ)
    e["HERDR_SOCKET_PATH"] = sock
    return e


def start_control(sock, target, takeover=False, cols=80, rows=24):
    # NB: this subcommand's parser wants <target> before any flags -- passing
    # --takeover ahead of the target mis-parses the target as an unknown
    # option (confirmed live: "unknown terminal session control option: ...").
    args = [HERDR, "terminal", "session", "control", target]
    if takeover:
        args.append("--takeover")
    args += ["--cols", str(cols), "--rows", str(rows)]
    return subprocess.Popen(
        args, env=env_for(sock),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )


def start_observe(sock, target, cols=80, rows=24):
    args = [HERDR, "terminal", "session", "observe", target,
            "--cols", str(cols), "--rows", str(rows)]
    return subprocess.Popen(
        args, env=env_for(sock),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )


def start_attach(sock, target, takeover=False, cols=80, rows=24):
    args = [HERDR, "terminal", "attach", target]
    if takeover:
        args.append("--takeover")
    args += ["--cols", str(cols), "--rows", str(rows)]
    return subprocess.Popen(
        args, env=env_for(sock),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )


def send(proc, obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def read_lines_for(proc, seconds):
    """Non-blocking-ish collection: read whatever stdout produces within a window."""
    import select
    end = time.time() + seconds
    lines = []
    while time.time() < end:
        r, _, _ = select.select([proc.stdout], [], [], max(0, end - time.time()))
        if proc.stdout in r:
            line = proc.stdout.readline()
            if line == "":
                break
            lines.append(line.rstrip("\n"))
    return lines


def decode_frame_text(line):
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return None
    if obj.get("type") != "terminal.frame":
        return None
    raw = base64.b64decode(obj["bytes"])
    return raw.decode("utf-8", errors="replace")


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                          capture_output=True, text=True).stdout.strip()
    return int(out) if out else None
