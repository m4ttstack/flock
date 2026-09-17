#!/usr/bin/env bash
# A herdr worktree group: a workspace on a git repo, plus the linked-worktree
# workspace herdr refuses to close it without. Both the repo and the checkout
# are made inside the work directory the wrapper already removes, so nothing
# of this survives the run and no repo of Matt's is ever touched.
#
# Prints {"primary":...,"linked":...,"primaryTab":...,"primaryPane":...}.
set -euo pipefail
sock="${1:?socket path}"
work="${2:?work directory}"

# A directory of its own per call: every case reseeds the session, so a run
# can ask for a group more than once, and a second checkout at the same path
# would be refused by git rather than by anything herdr says.
group=$(mktemp -d "$work/group-XXXXXX")
repo="$group/repo"
checkout="$group/linked"

req() { printf '%s\n' "$1" | nc -U "$sock" | head -1; }

field() {
  local value
  value=$(jq -r "$2" <<<"$1")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "seed-worktree-group.sh: $2 missing from herdr response: $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

mkdir -p "$repo"
git -C "$repo" init -q -b main
printf 'seed\n' > "$repo/README.md"
# Identity on the command line, never written into the repo's config or
# read from Matt's: a commit is only needed so the checkout below has a
# HEAD to branch from.
git -C "$repo" -c user.email=e2e@paddock.invalid -c user.name=paddock-e2e add README.md
git -C "$repo" -c user.email=e2e@paddock.invalid -c user.name=paddock-e2e commit -q -m "seed"

ws_resp=$(req "{\"id\":\"g1\",\"method\":\"workspace.create\",\"params\":{\"cwd\":\"$repo\",\"label\":\"primary\"}}")
primary=$(field "$ws_resp" .result.workspace.workspace_id)
primary_tab=$(field "$ws_resp" .result.tab.tab_id)
primary_pane=$(field "$ws_resp" .result.root_pane.pane_id)

# An explicit path keeps the checkout in the work directory: without one
# herdr places it under the configured worktrees directory, which is a real
# one in Matt's home.
wt_resp=$(req "{\"id\":\"g2\",\"method\":\"worktree.create\",\"params\":{\"workspace_id\":\"$primary\",\"branch\":\"paddock-e2e\",\"path\":\"$checkout\",\"focus\":false,\"trust_repository\":true}}")
linked=$(field "$wt_resp" .result.workspace.workspace_id)

jq -n --arg primary "$primary" --arg linked "$linked" \
      --arg primaryTab "$primary_tab" --arg primaryPane "$primary_pane" \
      '{primary:$primary,linked:$linked,primaryTab:$primaryTab,primaryPane:$primaryPane}'
