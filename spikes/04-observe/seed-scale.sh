#!/usr/bin/env bash
# Seeds a dedicated scratch workspace with N_TABS tabs of PER_TAB panes each,
# every pane running a 0.3s-interval date loop, then prints a JSON array of
# all pane ids. Splits are spread across tabs (not one giant tab) because
# herdr rejects a split once a pane gets too small.
set -euo pipefail
sock="${1:?socket path}"
n_tabs="${2:-6}"
per_tab="${3:-5}"

req() { printf '%s\n' "$1" | nc -U "$sock" | head -1; }

ws_resp=$(req '{"id":"ws","method":"workspace.create","params":{"cwd":"/tmp","label":"scale"}}')
ws=$(jq -r .result.workspace.workspace_id <<<"$ws_resp")
first_tab=$(jq -r .result.tab.tab_id <<<"$ws_resp")
first_root=$(jq -r .result.root_pane.pane_id <<<"$ws_resp")

all_panes=()

seed_tab() {
  local tab_id="$1" root_pane="$2" count="$3"
  local panes=("$root_pane")
  # 5 panes: right, then down each of the two, then right on one to get 5.
  local dirs=(right down down right)
  for d in "${dirs[@]}"; do
    if [ "${#panes[@]}" -ge "$count" ]; then break; fi
    local last_idx=$(( ${#panes[@]} - 1 ))
    local target="${panes[$last_idx]}"
    local resp
    resp=$(req "{\"id\":\"sp\",\"method\":\"pane.split\",\"params\":{\"target_pane_id\":\"$target\",\"direction\":\"$d\"}}")
    local new_pane
    new_pane=$(jq -r '.result.pane.pane_id // empty' <<<"$resp")
    if [ -z "$new_pane" ]; then
      echo "split failed on $target dir=$d: $resp" >&2
      continue
    fi
    panes+=("$new_pane")
  done
  for p in "${panes[@]}"; do
    all_panes+=("$p")
  done
}

seed_tab "$first_tab" "$first_root" "$per_tab"

for i in $(seq 2 "$n_tabs"); do
  tab_resp=$(req "{\"id\":\"t$i\",\"method\":\"tab.create\",\"params\":{\"workspace_id\":\"$ws\",\"label\":\"scale$i\"}}")
  tab_id=$(jq -r .result.tab.tab_id <<<"$tab_resp")
  root_pane=$(jq -r .result.root_pane.pane_id <<<"$tab_resp")
  seed_tab "$tab_id" "$root_pane" "$per_tab"
done

for p in "${all_panes[@]}"; do
  HERDR_SOCKET_PATH="$sock" /Users/matt/.local/bin/herdr pane run "$p" 'while true; do date; sleep 0.3; done' >/dev/null
done

printf '%s\n' "${all_panes[@]}" | jq -R . | jq -s --arg ws "$ws" '{workspace: $ws, panes: .}'
