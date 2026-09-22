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

# Sparkle replaces the running app at its own path, so only the Release build
# of Flock may carry the update feed: a Debug build or Flock-dev that did would
# swap itself for the latest release. Read from project.yml, which both the
# Info.plist keys and the updater's compile condition come from, so no build
# is needed.
SPARKLE_FEED_URL="https://github.com/m4ttstack/flock/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="JM4/Y2AM6z+8j7xVFUzH41zKhoCXvRPCPDOJwWCC4J0="

sparkle_check() {
  local json
  json=$(python3 -c 'import json,sys,yaml; json.dump(yaml.safe_load(open("project.yml")), sys.stdout)' 2>/dev/null \
    || ruby -ryaml -rjson -e 'print JSON.generate(YAML.safe_load(File.read("project.yml")))' 2>/dev/null) \
    || { echo "reading project.yml needs python3 with PyYAML, or ruby"; return 1; }
  PROJECT_JSON="$json" python3 - "$1" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY" <<'PY'
import json, os, re, subprocess, sys

mode, feed, key = sys.argv[1:4]
project = json.loads(os.environ["PROJECT_JSON"])
settings = ("FLOCK_SPARKLE_FEED_URL", "FLOCK_SPARKLE_PUBLIC_ED_KEY")
release_path = ("targets", "Flock", "settings", "configs", "Release")
problems = []

def at(node, path):
    for part in path:
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node

def where(path):
    return ".".join(path)

if mode == "release":
    release = at(project, release_path) or {}
    for name, want in zip(settings, (feed, key)):
        if release.get(name) != want:
            problems.append(f"{where(release_path + (name,))} is {release.get(name)!r}, expected {want!r}")
    if "FLOCK_SPARKLE" not in str(release.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")).split():
        problems.append(f"{where(release_path)} does not set the FLOCK_SPARKLE compilation condition")
    scripts = at(project, ("targets", "Flock", "postBuildScripts")) or []
    if not any(
        all(term in str(s.get("script", "")) for term in
            ("SUFeedURL", "SUPublicEDKey", "$FLOCK_SPARKLE_FEED_URL", "$FLOCK_SPARKLE_PUBLIC_ED_KEY"))
        for s in scripts
    ):
        problems.append("no postBuildScripts entry on Flock writes SUFeedURL and SUPublicEDKey from the settings")
else:
    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                here = path + (str(k),)
                allowed = path == release_path
                if (k in settings or re.match(r"SU[A-Z][a-z]", str(k))) and not allowed:
                    problems.append(f"{where(here)}: Sparkle key outside Flock's Release configuration")
                if k == "SWIFT_ACTIVE_COMPILATION_CONDITIONS" and "FLOCK_SPARKLE" in str(v) and not allowed:
                    problems.append(f"{where(here)}: FLOCK_SPARKLE outside Flock's Release configuration")
                if k == "script" and "SUFeedURL" in str(v) and path[:2] != ("targets", "Flock"):
                    problems.append(f"{where(here)}: a script outside the Flock target writes SUFeedURL")
                walk(v, here)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, path + (str(i),))
        elif isinstance(node, str) and (feed in node or key in node):
            if not (path[:-1] == release_path and path[-1] in settings):
                problems.append(f"{where(path)}: the feed URL or public key outside Flock's Release settings")
    walk(project, ())

    files = subprocess.run(["git", "ls-files", "-z", "*.swift"], capture_output=True, text=True).stdout.split("\0")
    importers = [f for f in files if f and re.search(r"^import Sparkle\b", open(f).read(), re.M)]
    if importers != ["Sources/Flock/Updates/Updater.swift"]:
        problems.append(f"import Sparkle belongs only in Sources/Flock/Updates/Updater.swift, found in {importers}")
    elif not open(importers[0]).read().startswith("#if FLOCK_SPARKLE\n"):
        problems.append(f"{importers[0]} must open with #if FLOCK_SPARKLE")
    excludes = next((s.get("excludes", []) for s in at(project, ("targets", "FlockChromeRender", "sources")) or []
                     if isinstance(s, dict) and s.get("path") == "Sources/Flock"), [])
    if "Updates/Updater.swift" not in excludes:
        problems.append("FlockChromeRender does not exclude Updates/Updater.swift")

print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
}
sparkle_release_ok() { sparkle_check release; }
sparkle_scoped_ok() { sparkle_check scoped; }

check "shell scripts parse" syntax_ok
check "Scripts/*.sh are executable" executable_ok
check "no em or en dashes" dashes_ok
check "project.yml is readable" project_yml_ok
check "Release Flock carries the Sparkle feed" sparkle_release_ok
check "no Sparkle feed in Debug or Flock-dev" sparkle_scoped_ok
check "repo purity" sh Scripts/repo-purity.sh

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks ok"
else
  echo "$fails check(s) failed"
  exit 1
fi
