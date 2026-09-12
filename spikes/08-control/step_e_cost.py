#!/usr/bin/env python3
"""Step E: per-pane cost of a `herdr terminal session control` child at 8
warm panes, plus a standalone non-takeover input-forwarding sanity check.
Throwaway, single-run script for task 18d.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from control_probe import start_control, read_lines_for, rss_kb  # noqa: E402

SOCK = sys.argv[1]


def p(*a):
    print(*a)
    sys.stdout.flush()


def req(method, params=None):
    line = json.dumps({"id": "probe", "method": method, "params": params or {}})
    out = subprocess.run(["nc", "-U", SOCK], input=line + "\n",
                          capture_output=True, text=True, timeout=5).stdout
    return json.loads(out.splitlines()[0])


# ---- sanity: plain non-takeover control forwards input with no contention ----
seed = json.loads(subprocess.run(
    ["bash", os.path.join(os.path.dirname(__file__), "..", "lib", "seed-layout.sh"), SOCK],
    capture_output=True, text=True, check=True).stdout)
p1 = seed["p1"]
solo = start_control(SOCK, p1, takeover=False)
time.sleep(0.4)
read_lines_for(solo, 0.2)
solo.stdin.write(json.dumps({"type": "terminal.input", "text": "echo SOLO_NONTAKEOVER_OK\n"}) + "\n")
solo.stdin.flush()
time.sleep(0.5)
out = req("pane.read", {"pane_id": p1, "source": "visible", "format": "text"})
p("solo non-takeover input landed:", "SOLO_NONTAKEOVER_OK" in out["result"]["read"]["text"])
solo.terminate()

# ---- 8-pane cost ----
pane_ids = [p1]
for i in range(7):
    ws = json.loads(subprocess.run(
        ["bash", "-c", f'printf "%s\\n" \'{{"id":"s{i}","method":"workspace.create","params":{{"cwd":"/tmp","label":"cost{i}"}}}}\' | nc -U {SOCK}'],
        capture_output=True, text=True, check=True).stdout.splitlines()[0])
    pane_ids.append(ws["result"]["root_pane"]["pane_id"])
p("panes:", pane_ids)

children = []
parent_pid = os.getpid()
for pane in pane_ids:
    c = start_control(SOCK, pane, takeover=True)
    children.append(c)
time.sleep(2.0)
for c in children:
    read_lines_for(c, 0.1)

total_rss = 0
per_child = []
for c in children:
    kb = rss_kb(c.pid)
    per_child.append((c.pid, kb))
    if kb:
        total_rss += kb
parent_kb = rss_kb(parent_pid)
p("per_child_rss_kb:", per_child)
p("sum_children_rss_kb:", total_rss, "avg_per_child_kb:", total_rss / len(children))
p("driver_process_rss_kb:", parent_kb)

for c in children:
    c.terminate()
time.sleep(0.3)
for c in children:
    try:
        c.kill()
    except Exception:
        pass
print("DONE", file=sys.stderr)
sys.stderr.flush()
os._exit(0)
