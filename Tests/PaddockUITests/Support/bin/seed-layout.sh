#!/usr/bin/env bash
# Canonical layout: ws with tabA (p1 | p2 side by side) and tabB (p3 alone).
set -euo pipefail
sock="${1:?socket path}"

# herdr's api socket answers exactly one request per connection and then
# closes it, so every request opens its own.
req() { printf '%s\n' "$1" | nc -U "$sock" | head -1; }

field() {
  local value
  value=$(jq -r "$2" <<<"$1")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "seed-layout.sh: $2 missing from herdr response: $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

ws_resp=$(req '{"id":"s1","method":"workspace.create","params":{"cwd":"/tmp","label":"seed"}}')
ws=$(field "$ws_resp" .result.workspace.workspace_id)
tabA=$(field "$ws_resp" .result.tab.tab_id)
p1=$(field "$ws_resp" .result.root_pane.pane_id)
split=$(req "{\"id\":\"s2\",\"method\":\"pane.split\",\"params\":{\"target_pane_id\":\"$p1\",\"direction\":\"right\"}}")
p2=$(field "$split" .result.pane.pane_id)
tabB_resp=$(req "{\"id\":\"s3\",\"method\":\"tab.create\",\"params\":{\"workspace_id\":\"$ws\",\"label\":\"tabB\"}}")
tabB=$(field "$tabB_resp" .result.tab.tab_id)
p3=$(field "$tabB_resp" .result.root_pane.pane_id)
jq -n --arg ws "$ws" --arg tabA "$tabA" --arg tabB "$tabB" \
      --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" \
      '{ws:$ws,tabA:$tabA,tabB:$tabB,p1:$p1,p2:$p2,p3:$p3}'
