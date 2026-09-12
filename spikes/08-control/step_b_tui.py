#!/usr/bin/env python3
"""Step B: does ClientControlTerminal{takeover:true} kick the ordinary
full-app herdr TUI (ClientShell mode), or only other direct-attach clients?
Throwaway, single-run script for task 18d.
"""
import json
import os
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from control_probe import start_control, env_for, read_lines_for  # noqa: E402
from pty_spawn import spawn, alive  # noqa: E402

SOCK = sys.argv[1]
SESSION_NAME = os.path.basename(os.path.dirname(SOCK))


def req(method, params=None):
    line = json.dumps({"id": "probe", "method": method, "params": params or {}})
    out = subprocess.run(["nc", "-U", SOCK], input=line + "\n",
                          capture_output=True, text=True, timeout=5).stdout
    return json.loads(out.splitlines()[0])


def p(*a):
    print(*a)
    sys.stdout.flush()


seed = json.loads(subprocess.run(
    ["bash", os.path.join(os.path.dirname(__file__), "..", "lib", "seed-layout.sh"), SOCK],
    capture_output=True, text=True, check=True).stdout)
p("seed", seed)
p1 = seed["p1"]

env = env_for(SOCK)
env.pop("HERDR_ENV", None)  # nested-herdr guard checks this exact var
pid, master_fd = spawn(["herdr", "--session", SESSION_NAME], env, rows=24, cols=80)
time.sleep(2.5)
p("tui alive before takeover:", alive(pid))

# drain whatever the TUI already painted, to prove the fd is live/readable
r, _, _ = select.select([master_fd], [], [], 0.5)
before_bytes = os.read(master_fd, 65536) if master_fd in r else b""
p("tui painted", len(before_bytes), "bytes before takeover")

ctl = start_control(SOCK, p1, takeover=True)
time.sleep(1.0)
ctl_out = read_lines_for(ctl, 0.3)
p("control channel attached ok, first line type:",
      json.loads(ctl_out[0])["type"] if ctl_out else None)

p("tui alive after takeover:", alive(pid))
r, _, _ = select.select([master_fd], [], [], 0.5)
after_bytes = os.read(master_fd, 65536) if master_fd in r else b""
p("tui produced", len(after_bytes), "more bytes after takeover (repaint still flowing)")

pane_after = req("pane.get", {"pane_id": p1})
p("pane still present after takeover:", pane_after)

# cleanup (non-blocking: this session's own herdr TUI can ignore SIGTERM
# while it owns the pty as session leader, so never wait() on it here)
try:
    ctl.terminate()
except Exception:
    pass
try:
    os.kill(pid, 9)
except Exception:
    pass
try:
    os.close(master_fd)
except Exception:
    pass
sys.stdout.flush()
print("DONE", file=sys.stderr)
sys.stderr.flush()
os._exit(0)
