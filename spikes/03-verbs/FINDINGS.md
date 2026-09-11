# Spike 03: mutation verb matrix + split-ratio paths

Findings from running spikes/03-verbs/run.sh against a scratch herdr 0.8.0 session (never the default ~/.config/herdr/herdr.sock). Every request is a fresh one-shot nc -U connection per spike 02's finding; the events subscription is a second, separate, receive-only connection read by a small unbuffered python3 reader. Each case seeds its own fresh workspace via spikes/lib/seed-layout.sh, so cases do not depend on each other's leftover state.

## Case 1: pane.move p1 -> tab tabB, target_pane_id p3, split right, ratio 0.5

**Verdict: PASS**

Seed: ws=w1 tabA=w1:t1 (p1=w1:p1, p2=w1:p2) tabB=w1:t2 (p3=w1:p3)

Raw pane.move response:
```
{
  "id": "c1",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w1:p1",
      "previous_workspace_id": "w1",
      "previous_tab_id": "w1:t1",
      "pane": {
        "pane_id": "w1:p1",
        "terminal_id": "term_65b2c82e73bef1",
        "workspace_id": "w1",
        "tab_id": "w1:t2",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w1",
        "tab_id": "w1:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w1:p2",
        "panes": [
          {
            "pane_id": "w1:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "w1",
        "tab_id": "w1:t2",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w1:p3",
        "panes": [
          {
            "pane_id": "w1:p3",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          },
          {
            "pane_id": "w1:p1",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "focused_pane_id": "w1:p3"
    }
  }
}
```
Assertion: changed=true, post-move tabA.pane_count=1 (want 1), tabB.pane_count=2 (want 2).

## Case 1b: pane.move with no target_pane_id -- default-pane polarity

**Verdict: PASS**

Seed: tabB=w2:t2 started with p3=w2:p3 only. Split p3 down to add p4=w2:p4, then explicitly focused p4 (not p3) before the nil-target move, so a correct default has to follow focus, not tab history.

Raw pane.split (built p4):
```
{
  "id": "c1b-split",
  "result": {
    "type": "pane_info",
    "pane": {
      "pane_id": "w2:p4",
      "terminal_id": "term_65b2c8306738c7",
      "workspace_id": "w2",
      "tab_id": "w2:t2",
      "focused": false,
      "cwd": "/private/tmp",
      "foreground_cwd": "/private/tmp",
      "agent_status": "unknown",
      "scroll": {
        "offset_from_bottom": 0,
        "max_offset_from_bottom": 0,
        "viewport_rows": 23
      },
      "revision": 0
    }
  }
}
```
Raw pane.move (nil target_pane_id) response:
```
{
  "id": "c1b",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w2:p1",
      "previous_workspace_id": "w2",
      "previous_tab_id": "w2:t1",
      "pane": {
        "pane_id": "w2:p1",
        "terminal_id": "term_65b2c82ff44b74",
        "workspace_id": "w2",
        "tab_id": "w2:t2",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w2",
        "tab_id": "w2:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w2:p2",
        "panes": [
          {
            "pane_id": "w2:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "w2",
        "tab_id": "w2:t2",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w2:p4",
        "panes": [
          {
            "pane_id": "w2:p3",
            "focused": false,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 12
            }
          },
          {
            "pane_id": "w2:p4",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 13,
              "width": 27,
              "height": 11
            }
          },
          {
            "pane_id": "w2:p1",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 13,
              "width": 27,
              "height": 11
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "down",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          },
          {
            "id": "split_1_1",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 13,
              "width": 54,
              "height": 11
            }
          }
        ]
      },
      "focused_pane_id": "w2:p4"
    }
  }
}
```
p1's post-move rect: y=13 height=11. Pane sharing that y-band (its split partner): w2:p4. Focused pane going in was w2:p4. Matches: nil target_pane_id splits against the destination tab's FOCUSED pane.

## Case 2: pane.move p2 -> new_tab (same workspace)

**Verdict: PASS**

Raw response:
```
{
  "id": "c2",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w3:p2",
      "previous_workspace_id": "w3",
      "previous_tab_id": "w3:t1",
      "pane": {
        "pane_id": "w3:p2",
        "terminal_id": "term_65b2c8328d2579",
        "workspace_id": "w3",
        "tab_id": "w3:t3",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 12
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w3",
        "tab_id": "w3:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w3:p1",
        "panes": [
          {
            "pane_id": "w3:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "w3",
        "tab_id": "w3:t3",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w3:p2",
        "panes": [
          {
            "pane_id": "w3:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "created_tab": {
        "tab_id": "w3:t3",
        "workspace_id": "w3",
        "number": 3,
        "label": "nt",
        "focused": false,
        "pane_count": 1,
        "agent_status": "unknown"
      },
      "focused_pane_id": "w3:p2"
    }
  }
}
```
new pane_id=w3:p2, previous_pane_id=w3:p2 (want both == w3:p2, i.e. unchanged), created_tab.tab_id=w3:t3, label=nt (want nt).

## Case 3: pane.move p3 -> new_workspace (cross-workspace re-key)

**Verdict: PASS**

Raw response:
```
{
  "id": "c3",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w4:p3",
      "previous_workspace_id": "w4",
      "previous_tab_id": "w4:t2",
      "pane": {
        "pane_id": "w5:p1",
        "terminal_id": "term_65b2c8341d26cd",
        "workspace_id": "w5",
        "tab_id": "w5:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 12
        },
        "revision": 0
      },
      "target_layout": {
        "workspace_id": "w5",
        "tab_id": "w5:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w5:p1",
        "panes": [
          {
            "pane_id": "w5:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "created_workspace": {
        "workspace_id": "w5",
        "number": 5,
        "label": "nw",
        "focused": false,
        "pane_count": 1,
        "tab_count": 1,
        "active_tab_id": "w5:t1",
        "agent_status": "unknown"
      },
      "created_tab": {
        "tab_id": "w5:t1",
        "workspace_id": "w5",
        "number": 1,
        "label": "main",
        "focused": false,
        "pane_count": 1,
        "agent_status": "unknown"
      },
      "closed_tab_id": "w4:t2",
      "focused_pane_id": "w5:p1"
    }
  }
}
```
### Cross-workspace re-key example

| old pane id | new pane id | new workspace | new workspace label | new tab label |
|---|---|---|---|---|
| w4:p3 | w5:p1 | w5 | nw | main |

### Lifecycle events observed in the 0.7s window after the request (ts >= send time)

```
layout_updated
workspace_created
tab_created
tab_closed
pane_moved
```
pane_closed/pane_created events referencing the MOVED pane (w4:p3 / w5:p1) specifically: 0 (want 0 -- the re-key itself must ride on pane.moved alone).
Total pane_closed/pane_created events anywhere in the window (any pane): 0.

## Case 4: left-edge composition (move split:right, then swap)

**Verdict: PASS**

Raw pane.move response:
```
{
  "id": "c4-move",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w6:p3",
      "previous_workspace_id": "w6",
      "previous_tab_id": "w6:t2",
      "pane": {
        "pane_id": "w6:p3",
        "terminal_id": "term_65b2c8356c4d210",
        "workspace_id": "w6",
        "tab_id": "w6:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 12
        },
        "revision": 0
      },
      "target_layout": {
        "workspace_id": "w6",
        "tab_id": "w6:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w6:p1",
        "panes": [
          {
            "pane_id": "w6:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 14,
              "height": 23
            }
          },
          {
            "pane_id": "w6:p3",
            "focused": false,
            "rect": {
              "x": 40,
              "y": 1,
              "width": 13,
              "height": 23
            }
          },
          {
            "pane_id": "w6:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          },
          {
            "id": "split_1_0",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ]
      },
      "closed_tab_id": "w6:t2",
      "focused_pane_id": "w6:p1"
    }
  }
}
```
Raw pane.swap response:
```
{
  "id": "c4-swap",
  "result": {
    "type": "pane_swap",
    "swap": {
      "changed": true,
      "source_pane_id": "w6:p3",
      "target_pane_id": "w6:p1",
      "focused_pane_id": "w6:p3",
      "layout": {
        "workspace_id": "w6",
        "tab_id": "w6:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w6:p3",
        "panes": [
          {
            "pane_id": "w6:p3",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 14,
              "height": 23
            }
          },
          {
            "pane_id": "w6:p1",
            "focused": false,
            "rect": {
              "x": 40,
              "y": 1,
              "width": 13,
              "height": 23
            }
          },
          {
            "pane_id": "w6:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          },
          {
            "id": "split_1_0",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ]
      }
    }
  }
}
```
p1.x before swap=26, p3.x before swap=40 (split:right places the moved-in pane to the RIGHT). After swap: p1.x=40, p3.x=26 (want p3.x < p1.x, i.e. moved pane now on the LEFT).

## Case 5: same-tab bounce (no-op, then bounce below old sibling)

**Verdict: PASS**

Raw same-tab move response (expect changed:false reason:same_tab):
```
{
  "id": "c5-noop",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": false,
      "reason": "same_tab",
      "previous_pane_id": "w7:p1",
      "previous_workspace_id": "w7",
      "previous_tab_id": "w7:t1",
      "pane": {
        "pane_id": "w7:p1",
        "terminal_id": "term_65b2c8380e60311",
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w7:p1",
        "panes": [
          {
            "pane_id": "w7:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          },
          {
            "pane_id": "w7:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "target_layout": {
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w7:p1",
        "panes": [
          {
            "pane_id": "w7:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          },
          {
            "pane_id": "w7:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "focused_pane_id": "w7:p1"
    }
  }
}
```
Raw bounce-out (new_tab) response:
```
{
  "id": "c5-out",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w7:p1",
      "previous_workspace_id": "w7",
      "previous_tab_id": "w7:t1",
      "pane": {
        "pane_id": "w7:p1",
        "terminal_id": "term_65b2c8380e60311",
        "workspace_id": "w7",
        "tab_id": "w7:t3",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w7:p2",
        "panes": [
          {
            "pane_id": "w7:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "w7",
        "tab_id": "w7:t3",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w7:p1",
        "panes": [
          {
            "pane_id": "w7:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "created_tab": {
        "tab_id": "w7:t3",
        "workspace_id": "w7",
        "number": 3,
        "label": "3",
        "focused": false,
        "pane_count": 1,
        "agent_status": "unknown"
      },
      "focused_pane_id": "w7:p1"
    }
  }
}
```
Raw bounce-back (target_pane_id=w7:p2, split:down) response:
```
{
  "id": "c5-back",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w7:p1",
      "previous_workspace_id": "w7",
      "previous_tab_id": "w7:t3",
      "pane": {
        "pane_id": "w7:p1",
        "terminal_id": "term_65b2c8380e60311",
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "target_layout": {
        "workspace_id": "w7",
        "tab_id": "w7:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w7:p2",
        "panes": [
          {
            "pane_id": "w7:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 12
            }
          },
          {
            "pane_id": "w7:p1",
            "focused": false,
            "rect": {
              "x": 26,
              "y": 13,
              "width": 54,
              "height": 11
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "down",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "closed_tab_id": "w7:t3",
      "focused_pane_id": "w7:p2"
    }
  }
}
```
Raw tab.close (temp tab w7:t3) response:
```
{
  "id": "c5-close",
  "error": {
    "code": "tab_not_found",
    "message": "tab w7:t3 not found"
  }
}
```
The temp tab auto-closed when its last pane (the bounced pane) moved back out in the prior step, which is why the explicit tab.close above gets tab_not_found rather than an ok -- Task 20's bounce composition should treat that tab.close as optional cleanup, not something to depend on succeeding.
no-op: changed=false reason=same_tab. bounce pane id unchanged: w7:p1 (want w7:p1). Final rects: p1 y=13 x=26, p2 y=1 x=26 (want p1.y > p2.y, i.e. p1 below p2).

## Case 6: zoom guard

**Verdict: PASS**

Raw pane.move while zoomed (expect reason:zoomed_tab):
```
{
  "id": "c6-blocked",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": false,
      "reason": "zoomed_tab",
      "previous_pane_id": "w8:p3",
      "previous_workspace_id": "w8",
      "previous_tab_id": "w8:t2",
      "pane": {
        "pane_id": "w8:p3",
        "terminal_id": "term_65b2c83cfeb1f16",
        "workspace_id": "w8",
        "tab_id": "w8:t2",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "w8",
        "tab_id": "w8:t2",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w8:p3",
        "panes": [
          {
            "pane_id": "w8:p3",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "w8",
        "tab_id": "w8:t1",
        "zoomed": true,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w8:p1",
        "panes": [
          {
            "pane_id": "w8:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          },
          {
            "pane_id": "w8:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "focused_pane_id": "w8:p1"
    }
  }
}
```
Raw pane.move after un-zoom (expect success):
```
{
  "id": "c6-retry",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "w8:p3",
      "previous_workspace_id": "w8",
      "previous_tab_id": "w8:t2",
      "pane": {
        "pane_id": "w8:p3",
        "terminal_id": "term_65b2c83cfeb1f16",
        "workspace_id": "w8",
        "tab_id": "w8:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "target_layout": {
        "workspace_id": "w8",
        "tab_id": "w8:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "w8:p1",
        "panes": [
          {
            "pane_id": "w8:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 14,
              "height": 23
            }
          },
          {
            "pane_id": "w8:p3",
            "focused": false,
            "rect": {
              "x": 40,
              "y": 1,
              "width": 13,
              "height": 23
            }
          },
          {
            "pane_id": "w8:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          },
          {
            "id": "split_1_0",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ]
      },
      "closed_tab_id": "w8:t2",
      "focused_pane_id": "w8:p1"
    }
  }
}
```
blocked: changed=false reason=zoomed_tab. retry: changed=true. Final tabA.pane_count=3 (want 3).

## Case 7: layout.set_split_ratio path polarity

**Verdict: PASS** (root path:[] = PASS; echo=55ms)

### Part A: path:[] ratio 0.7 on the 2-pane tab

Raw response:
```
{
  "id": "c7a",
  "result": {
    "type": "layout_split_ratio_set",
    "layout": {
      "workspace_id": "w9",
      "tab_id": "w9:t1",
      "zoomed": false,
      "focused_pane_id": "w9:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.7,
        "first": {
          "type": "pane",
          "pane_id": "w9:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "pane",
          "pane_id": "w9:p2",
          "cwd": "/private/tmp"
        }
      }
    }
  }
}
```
layout.export root.ratio after = 0.7 (want 0.7).

### Part B: 3-pane tab (p1 | [p2 / p4], root split right, nested split down)

Tree before either path test (layout.export):
```
{
  "id": "c7b-export0",
  "result": {
    "type": "layout_export",
    "layout": {
      "workspace_id": "w9",
      "tab_id": "w9:t1",
      "zoomed": false,
      "focused_pane_id": "w9:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.7,
        "first": {
          "type": "pane",
          "pane_id": "w9:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "split",
          "direction": "down",
          "ratio": 0.5,
          "first": {
            "type": "pane",
            "pane_id": "w9:p2",
            "cwd": "/private/tmp"
          },
          "second": {
            "type": "pane",
            "pane_id": "w9:p4",
            "cwd": "/private/tmp"
          }
        }
      }
    }
  }
}
```
root.ratio before=0.7, nested.ratio before=0.5.

path:[true] ratio:0.2 response:
```
{
  "id": "c7-true",
  "result": {
    "type": "layout_split_ratio_set",
    "layout": {
      "workspace_id": "w9",
      "tab_id": "w9:t1",
      "zoomed": false,
      "focused_pane_id": "w9:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.7,
        "first": {
          "type": "pane",
          "pane_id": "w9:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "split",
          "direction": "down",
          "ratio": 0.2,
          "first": {
            "type": "pane",
            "pane_id": "w9:p2",
            "cwd": "/private/tmp"
          },
          "second": {
            "type": "pane",
            "pane_id": "w9:p4",
            "cwd": "/private/tmp"
          }
        }
      }
    }
  }
}
```
Resulting tree:
```
{
  "id": "c7-true-export",
  "result": {
    "type": "layout_export",
    "layout": {
      "workspace_id": "w9",
      "tab_id": "w9:t1",
      "zoomed": false,
      "focused_pane_id": "w9:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.7,
        "first": {
          "type": "pane",
          "pane_id": "w9:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "split",
          "direction": "down",
          "ratio": 0.2,
          "first": {
            "type": "pane",
            "pane_id": "w9:p2",
            "cwd": "/private/tmp"
          },
          "second": {
            "type": "pane",
            "pane_id": "w9:p4",
            "cwd": "/private/tmp"
          }
        }
      }
    }
  }
}
```
root.ratio=0.7, nested.ratio=0.2.

path:[false] ratio:0.6 response:
```
{
  "id": "c7-false",
  "error": {
    "code": "split_not_found",
    "message": "split path not found"
  }
}
```
Resulting tree:
```
{
  "id": "c7-false-export",
  "result": {
    "type": "layout_export",
    "layout": {
      "workspace_id": "w9",
      "tab_id": "w9:t1",
      "zoomed": false,
      "focused_pane_id": "w9:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.7,
        "first": {
          "type": "pane",
          "pane_id": "w9:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "split",
          "direction": "down",
          "ratio": 0.2,
          "first": {
            "type": "pane",
            "pane_id": "w9:p2",
            "cwd": "/private/tmp"
          },
          "second": {
            "type": "pane",
            "pane_id": "w9:p4",
            "cwd": "/private/tmp"
          }
        }
      }
    }
  }
}
```
root.ratio=0.7, nested.ratio=0.2.

### Polarity table

| path | node addressed | evidence |
|---|---|---|
| [] | root split (the only split in a 2-pane tab) | root.ratio -> 0.7 |
| [true] | nested split (second child of root) | root.ratio=0.7, nested.ratio=0.2 |
| [false] | error: split_not_found | root.ratio=0.7, nested.ratio=0.2 |

## Case 8: whole-tab migration preserves split shape

**Verdict: PASS**

Source tabA layout (direction=right, ratio=0.5):
```
{
  "id": "c8-export0",
  "result": {
    "type": "layout_export",
    "layout": {
      "workspace_id": "wA",
      "tab_id": "wA:t1",
      "zoomed": false,
      "focused_pane_id": "wA:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.5,
        "first": {
          "type": "pane",
          "pane_id": "wA:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "pane",
          "pane_id": "wA:p2",
          "cwd": "/private/tmp"
        }
      }
    }
  }
}
```
Move p1 -> new_workspace (label dest, tab_label migrated), new pane=wB:p1 in tab=wB:t1, workspace=wB:
```
{
  "id": "c8-move1",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "wA:p1",
      "previous_workspace_id": "wA",
      "previous_tab_id": "wA:t1",
      "pane": {
        "pane_id": "wB:p1",
        "terminal_id": "term_65b2c846b90f31b",
        "workspace_id": "wB",
        "tab_id": "wB:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "source_layout": {
        "workspace_id": "wA",
        "tab_id": "wA:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "wA:p2",
        "panes": [
          {
            "pane_id": "wA:p2",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "target_layout": {
        "workspace_id": "wB",
        "tab_id": "wB:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "wB:p1",
        "panes": [
          {
            "pane_id": "wB:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ],
        "splits": []
      },
      "created_workspace": {
        "workspace_id": "wB",
        "number": 11,
        "label": "dest",
        "focused": false,
        "pane_count": 1,
        "tab_count": 1,
        "active_tab_id": "wB:t1",
        "agent_status": "unknown"
      },
      "created_tab": {
        "tab_id": "wB:t1",
        "workspace_id": "wB",
        "number": 1,
        "label": "migrated",
        "focused": false,
        "pane_count": 1,
        "agent_status": "unknown"
      },
      "focused_pane_id": "wB:p1"
    }
  }
}
```
Move p2 -> tab destination in new_tab, replaying direction=right ratio=0.5, new pane=wB:p2:
```
{
  "id": "c8-move2",
  "result": {
    "type": "pane_move",
    "move_result": {
      "changed": true,
      "previous_pane_id": "wA:p2",
      "previous_workspace_id": "wA",
      "previous_tab_id": "wA:t1",
      "pane": {
        "pane_id": "wB:p2",
        "terminal_id": "term_65b2c846bf5d11c",
        "workspace_id": "wB",
        "tab_id": "wB:t1",
        "focused": false,
        "cwd": "/private/tmp",
        "foreground_cwd": "/private/tmp",
        "agent_status": "unknown",
        "scroll": {
          "offset_from_bottom": 0,
          "max_offset_from_bottom": 0,
          "viewport_rows": 23
        },
        "revision": 0
      },
      "target_layout": {
        "workspace_id": "wB",
        "tab_id": "wB:t1",
        "zoomed": false,
        "area": {
          "x": 26,
          "y": 1,
          "width": 54,
          "height": 23
        },
        "focused_pane_id": "wB:p1",
        "panes": [
          {
            "pane_id": "wB:p1",
            "focused": true,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 27,
              "height": 23
            }
          },
          {
            "pane_id": "wB:p2",
            "focused": false,
            "rect": {
              "x": 53,
              "y": 1,
              "width": 27,
              "height": 23
            }
          }
        ],
        "splits": [
          {
            "id": "split_0_root",
            "direction": "right",
            "ratio": 0.5,
            "rect": {
              "x": 26,
              "y": 1,
              "width": 54,
              "height": 23
            }
          }
        ]
      },
      "closed_tab_id": "wA:t1",
      "focused_pane_id": "wB:p1"
    }
  }
}
```
Destination tab layout after:
```
{
  "id": "c8-export1",
  "result": {
    "type": "layout_export",
    "layout": {
      "workspace_id": "wB",
      "tab_id": "wB:t1",
      "zoomed": false,
      "focused_pane_id": "wB:p1",
      "root": {
        "type": "split",
        "direction": "right",
        "ratio": 0.5,
        "first": {
          "type": "pane",
          "pane_id": "wB:p1",
          "cwd": "/private/tmp"
        },
        "second": {
          "type": "pane",
          "pane_id": "wB:p2",
          "cwd": "/private/tmp"
        }
      }
    }
  }
}
```
direction after=right (want right), ratio after=0.5 (want 0.5).

## Event-echo timing distribution

Samples (ms), send -> matching layout_updated/pane_moved arrival, n=17:

```
45
35
57
99
64
100
10
50
108
39
24
28
55
24
92
104
89
```
min=10ms, median=55ms, max=108ms. The server polls for events every 100ms per the design doc; most samples should land at or under roughly one poll interval.

## Summary for Tasks 20/23

- Case totals: PASS=9 FAIL=0 DIVERGED=0.
- Every mutating call opened its own one-shot connection (spike 02's finding); the subscription connection was never interleaved with a request.
- Case 3's cross-workspace re-key: old/new pane id pair recorded above. In this run pane_moved was the only pane-lifecycle event for the whole new_workspace move (no pane_closed/pane_created at all, for the moved pane or otherwise); Task 20/23 planners can treat pane.moved as authoritative for re-keying local pane-id state without reconciling a close/create pair. Note the case's own bad-event check only gates on events referencing the moved pane's old/new id specifically, in case a future herdr version does add bootstrap noise around a new_workspace/new_tab destination -- see that case's verdict (DIVERGED, not FAIL, if it ever does).
- Case 7's polarity table is the key new fact for the geometry engine: see the table above for which of true/false in a path element addresses which child.

