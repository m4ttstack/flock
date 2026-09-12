#!/usr/bin/env python3
"""Throwaway driver for the task-18d control-transport probe.

Runs against ONE scratch herdr session (socket passed as argv[1]). Prints one
JSON line of results per step to stdout; redirect to a transcript file.
Never touches the default socket -- the caller is responsible for using
spikes/lib/scratch-session.sh to provision the socket it passes in.
"""
import base64
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from control_probe import (  # noqa: E402
    start_control, start_observe, start_attach, send, read_lines_for,
    decode_frame_text, rss_kb, env_for,
)

SOCK = sys.argv[1]


def req(method, params=None):
    line = json.dumps({"id": "probe", "method": method, "params": params or {}})
    out = subprocess.run(["nc", "-U", SOCK], input=line + "\n",
                          capture_output=True, text=True, timeout=5).stdout
    return json.loads(out.splitlines()[0])


def pane_get(pane_id):
    return req("pane.get", {"pane_id": pane_id})


def result(name, **kw):
    print(json.dumps({"step": name, **kw}))
    sys.stdout.flush()


def kill(proc):
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


# ---- seed a fresh layout ----
seed = json.loads(subprocess.run(
    ["bash", os.path.join(os.path.dirname(__file__), "..", "lib", "seed-layout.sh"), SOCK],
    capture_output=True, text=True, check=True).stdout)
result("seed", **seed)
p1, p2, p3 = seed["p1"], seed["p2"], seed["p3"]

# =========================================================================
# Step A: takeover semantics (non-takeover reject, takeover kicks the owner)
# =========================================================================
a = start_control(SOCK, p1, takeover=False)
time.sleep(0.5)
a_frames = read_lines_for(a, 0.3)

b = start_control(SOCK, p1, takeover=False)
b_out = read_lines_for(b, 1.0)
b.wait(timeout=2)
result("A_non_takeover_second_client", b_exit=b.returncode, b_out=b_out)

c = start_control(SOCK, p1, takeover=True)
time.sleep(0.5)
a_out_after_takeover = read_lines_for(a, 1.0)
a_rc = a.poll()
c_out = read_lines_for(c, 0.3)
result("A_takeover_kicks_first_owner", a_exit=a_rc, a_out_after=a_out_after_takeover,
       c_out=c_out, c_alive=(c.poll() is None))

# confirm c (the survivor) can still drive input
send(c, {"type": "terminal.input", "text": "echo TAKEOVER_SURVIVOR_OK\n"})
time.sleep(0.5)
read_out = req("pane.read", {"pane_id": p1, "source": "visible", "format": "text"})
result("A_survivor_input_lands", read_result=read_out)
kill(c)

# =========================================================================
# Step B: does a plain full-app TUI (ClientShell) get kicked by takeover?
# =========================================================================
tui = subprocess.Popen(
    ["script", "-q", "/dev/null", "herdr", "--session",
     os.path.basename(os.path.dirname(SOCK)), "--cols", "80", "--rows", "24"],
    env=env_for(SOCK), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
time.sleep(2.0)
tui_alive_before = tui.poll() is None
ctl = start_control(SOCK, p2, takeover=True)
time.sleep(1.0)
tui_alive_after = tui.poll() is None
pane_list_after = req("pane.list", {})
result("B_tui_shell_unaffected_by_takeover", tui_alive_before=tui_alive_before,
       tui_alive_after=tui_alive_after,
       panes_after=[p["pane_id"] for p in pane_list_after.get("result", {}).get("panes", [])])
kill(ctl)
kill(tui)

# =========================================================================
# Step C: resize -- control channel vs observe channel
# =========================================================================
before = pane_get(p1)
before_rows = before["result"]["pane"]["scroll"]["viewport_rows"]

ctl = start_control(SOCK, p1, takeover=True)
time.sleep(0.3)
send(ctl, {"type": "terminal.resize", "cols": 100, "rows": before_rows + 11})
time.sleep(0.5)
after_control = pane_get(p1)
after_control_rows = after_control["result"]["pane"]["scroll"]["viewport_rows"]
kill(ctl)
time.sleep(0.3)

obs = start_observe(SOCK, p1, cols=100, rows=before_rows + 20)
time.sleep(0.5)
after_observe = pane_get(p1)
after_observe_rows = after_observe["result"]["pane"]["scroll"]["viewport_rows"]
kill(obs)

result("C_resize_scope", before_rows=before_rows,
       after_control_resize_rows=after_control_rows,
       after_observe_open_rows=after_observe_rows)

# =========================================================================
# Step D: scroll scope -- shared pane viewport vs per-attach-client
# =========================================================================
gen = start_control(SOCK, p3, takeover=True)
time.sleep(0.3)
send(gen, {"type": "terminal.input", "text": "for i in $(seq 1 300); do echo scrollline-$i; done\n"})
time.sleep(1.5)
scroll_before = pane_get(p3)["result"]["pane"]["scroll"]

obs2 = start_observe(SOCK, p3, cols=80, rows=24)
time.sleep(0.3)
obs2_frames_before = [decode_frame_text(l) for l in read_lines_for(obs2, 0.5)]
obs2_frames_before = [f for f in obs2_frames_before if f]

send(gen, {"type": "terminal.scroll", "direction": "up", "lines": 40})
time.sleep(0.5)
scroll_after = pane_get(p3)["result"]["pane"]["scroll"]
obs2_frames_after = [decode_frame_text(l) for l in read_lines_for(obs2, 0.5)]
obs2_frames_after = [f for f in obs2_frames_after if f]

result("D_scroll_scope", scroll_before=scroll_before, scroll_after=scroll_after,
       observer_saw_new_frame_after_scroll=bool(obs2_frames_after),
       observer_last_frame_before=(obs2_frames_before[-1] if obs2_frames_before else None),
       observer_last_frame_after=(obs2_frames_after[-1] if obs2_frames_after else None))

send(gen, {"type": "terminal.scroll", "direction": "down", "lines": 100})
time.sleep(0.3)
scroll_reset = pane_get(p3)["result"]["pane"]["scroll"]
result("D_scroll_reset", scroll_reset=scroll_reset)
kill(gen)
kill(obs2)

print("DONE", file=sys.stderr)
