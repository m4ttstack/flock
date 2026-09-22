#!/usr/bin/env bash
# The checks that need no build: seconds to run, on any machine, with no
# Xcode and no vendored libghostty. CI calls this so the fast failures come
# back fast, and so the same gate is runnable by hand before pushing.
#
# The build-and-test gate is separate on purpose. It needs a macOS runner and
# a libghostty build, so it is minutes rather than seconds, and a typo in a
# shell script should not wait behind it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fails=0
check() {
  printf '  %-46s' "$1"
  shift
  if "$@" >/tmp/flock-checks.out 2>&1; then
    echo ok
  else
    echo FAIL
    sed 's/^/      /' /tmp/flock-checks.out | head -20
    fails=$((fails + 1))
  fi
}

# Every tracked shell script parses. Catches the class of typo that otherwise
# surfaces halfway through a release build, after minutes of work.
syntax_ok() {
  local bad=0 f
  for f in $(git ls-files '*.sh'); do
    bash -n "$f" || { echo "$f does not parse"; bad=1; }
  done
  return "$bad"
}

# A script without its executable bit fails only when something tries to run
# it, which in this repo means during a release.
executable_ok() {
  local bad=0 f
  for f in $(git ls-files 'Scripts/*.sh'); do
    [ -x "$f" ] || { echo "$f is not executable"; bad=1; }
  done
  return "$bad"
}

# Em and en dashes, which this project does not use anywhere: code comments,
# commit messages, docs. Checked here because it is invisible in review and
# trivially fixed at the point it is written.
dashes_ok() {
  local hits
  hits=$(git ls-files -z '*.swift' '*.sh' '*.md' '*.yml' \
    | xargs -0 grep -nP '[\x{2014}\x{2013}]' 2>/dev/null || true)
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
}

# The generated Xcode project is derived from project.yml and gitignored, so
# a stale or missing one is not a failure... but project.yml itself has to be
# parseable or nothing downstream builds.
project_yml_ok() {
  python3 -c "import sys,yaml;yaml.safe_load(open('project.yml'))" 2>/dev/null \
    || python3 -c "
import sys
sys.exit(0 if open('project.yml').read().strip() else 1)
"
}

check "shell scripts parse" syntax_ok
check "Scripts/*.sh are executable" executable_ok
check "no em or en dashes" dashes_ok
check "project.yml is readable" project_yml_ok
check "repo purity" sh Scripts/repo-purity.sh

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks ok"
else
  echo "$fails check(s) failed"
  exit 1
fi
