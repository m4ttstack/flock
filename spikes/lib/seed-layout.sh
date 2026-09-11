#!/usr/bin/env bash
# Canonical layout: ws with tabA (p1 | p2 side by side) and tabB (p3 alone).
set -euo pipefail
sock="${1:?socket path}"
req() { printf '%s\n' "$1" | nc -U "$sock" | head -1; }
ws_resp=$(req '{"id":"s1","method":"workspace.create","params":{"cwd":"/tmp","label":"seed"}}')
ws=$(jq -r .result.workspace.workspace_id <<<"$ws_resp")
tabA=$(jq -r .result.tab.tab_id <<<"$ws_resp")
p1=$(jq -r .result.root_pane.pane_id <<<"$ws_resp")
split=$(req "{\"id\":\"s2\",\"method\":\"pane.split\",\"params\":{\"target_pane_id\":\"$p1\",\"direction\":\"right\"}}")
p2=$(jq -r .result.pane.pane_id <<<"$split")
tabB_resp=$(req "{\"id\":\"s3\",\"method\":\"tab.create\",\"params\":{\"workspace_id\":\"$ws\",\"label\":\"tabB\"}}")
tabB=$(jq -r .result.tab.tab_id <<<"$tabB_resp")
p3=$(jq -r .result.root_pane.pane_id <<<"$tabB_resp")
jq -n --arg ws "$ws" --arg tabA "$tabA" --arg tabB "$tabB" \
      --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" \
      '{ws:$ws,tabA:$tabA,tabB:$tabB,p1:$p1,p2:$p2,p3:$p3}'
