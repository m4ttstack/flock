# Spike: Protocol Floor Pinned

## Evidence Summary

MINIMUM_PROTOCOL = 22

## Verification Results

### Version & Schema Check

- **herdr version**: 0.9.0 (confirmed via `herdr --version`)
- **Schema protocol field**: 22 (confirmed via `herdr api schema --json | jq '.protocol'`)

### Required Methods Present

All required methods confirmed present in schema via `herdr api schema --json`:

| Method | Status |
|--------|--------|
| pane.scroll | Present |
| pane.selection.read | Present |
| pane.copy_search | Present |
| pane.link.activate | Present |
| pane.input.set | Present |
| tab.move | Present |
| workspace.move | Present |

### Live Protocol Confirmation

Scratch session protocol check via live socket ping:

```json
{
  "id": "p1",
  "result": {
    "type": "pong",
    "version": "0.9.0",
    "protocol": 22,
    "capabilities": {
      "live_handoff": true,
      "detached_server_daemon": false,
      "endpoint_protocol_generation": 1,
      "surface_interest": true,
      "health_check": true
    }
  }
}
```

Protocol from live socket: 22

### Verb Matrix Verification

Ran spikes/03-verbs/run.sh against herdr 0.9.0 with protocol 22:

```
PASS=9 FAIL=0 DIVERGED=0
```

All verb tests pass on protocol 22.

### Preview Channel

Preview channel version not remotely determinable within ~10 minutes of probing. Stable ships 0.9.0/protocol 22 which meets the floor.

## Conclusion

**MINIMUM_PROTOCOL = 22** is confirmed and ready for pinning.

- Version: 0.9.0
- Protocol: 22
- All required methods present
- All verb tests pass
- Live socket protocol verified
- No plan-constraint change needed (Global Constraints already specifies 22)
