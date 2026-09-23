#!/usr/bin/env bash
# Builds the dev flavor, Flock-dev.app ("Flock Dev"), into build/dev/.
#
# The dev flavor exists so a rebuild is what you test: rerun this script after
# an edit and open the same path again, no /Applications install and no
# notarization round trip in the way. It carries a distinct bundle id
# (dev.mattstack.Flock.dev vs the prod dev.mattstack.Flock) so it never
# shadows or replaces an installed Flock.app, and Scripts/release-build.sh
# stays the only path that produces the signed, notarized release artifact.
#
# Signed with the machine's sole Developer ID Application identity when there
# is one, else ad-hoc, and never notarized. The Developer ID is for macOS's
# privacy grants, not Gatekeeper: they are keyed to the signature, and an
# ad-hoc one changes with every build, so each rebuild asked for folder access
# all over again. spctl is skipped because a bundle nobody notarized fails it
# on principle.
#
# Every build carries a stamp (FlockBuildStamp), and lands by rename, so a
# running Flock Dev sees exactly one change in build/dev and offers a restart
# onto the new build.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUTPUT_DIR="build/dev"
DERIVED_DIR="build/dev-derived"
VERIFY=1
ADHOC=0

usage() {
  cat <<'USAGE'
usage: Scripts/dev-build.sh [options]
  --output <dir>     where Flock-dev.app is written (default: build/dev). A
                     relative path resolves against the repo root, not the
                     directory this was invoked from.
  --skip-verify      build and sign without the codesign checks
  --adhoc            sign ad-hoc even when a Developer ID is available
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ -n "${2:-}" ] || { echo "dev-build.sh: --output needs a value" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --skip-verify) VERIFY=0; shift ;;
    --adhoc) ADHOC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dev-build.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in git xcodegen xcodebuild codesign ditto security; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "dev-build.sh: $tool is required" >&2; exit 1
  }
done

APP_OUT="$OUTPUT_DIR/Flock-dev.app"

Scripts/libghostty.sh --check
xcodegen

mkdir -p "$OUTPUT_DIR"

IDENTITY="-"
if [ "$ADHOC" = 0 ]; then
  candidates=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')
  [ "$(printf '%s' "$candidates" | grep -c . || true)" = 1 ] && IDENTITY="$candidates"
fi

DIRTY=""
[ -n "$(git status --porcelain --untracked-files=no)" ] && DIRTY="+dirty"
STAMP="$(date '+%Y-%m-%d %H:%M:%S') $(git rev-parse --short HEAD)$DIRTY"

xcodebuild -scheme Flock-dev -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--options runtime" \
  FLOCK_BUILD_STAMP="$STAMP" \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Flock-dev.app"
[ -d "$BUILT_APP" ] || {
  echo "dev-build.sh: the build produced no $BUILT_APP" >&2; exit 1
}

# The previous output is replaced only once there is a whole new bundle
# beside it, so a failed build leaves the last good one, and the swap itself
# is two renames a watcher cannot catch halfway through a copy.
INCOMING="$OUTPUT_DIR/.Flock-dev.app.incoming"
OUTGOING="$OUTPUT_DIR/.Flock-dev.app.outgoing"
rm -rf "$INCOMING" "$OUTGOING"
ditto "$BUILT_APP" "$INCOMING"
[ -e "$APP_OUT" ] && mv "$APP_OUT" "$OUTGOING"
mv "$INCOMING" "$APP_OUT"
rm -rf "$OUTGOING"

if [ "$VERIFY" = 1 ]; then
  echo
  echo "=== codesign -vvv --deep --strict ==="
  codesign -vvv --deep --strict "$APP_OUT"

  echo
  echo "=== codesign -dv --verbose=4 ==="
  codesign -dv --verbose=4 "$APP_OUT" 2>&1
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_OUT/Contents/Info.plist")

echo
echo "dev-build.sh: $APP_OUT"
echo "dev-build.sh: bundle id $BUNDLE_ID, stamp $STAMP"
echo "dev-build.sh: signed by ${IDENTITY/#-/ad-hoc}"
echo "dev-build.sh: open \"$APP_OUT\" to launch; rerun this script after an edit and reopen the same path, no install step"
