#!/usr/bin/env bash
# Builds the dev flavor, Flock-dev.app, ad-hoc signed, into build/dev/.
#
# The dev flavor exists so a rebuild is what you test: rerun this script after
# an edit and open the same path again, no /Applications install and no
# notarization round trip in the way. It carries a distinct bundle id
# (dev.mattstack.Flock.dev vs the prod dev.mattstack.Flock) so it never
# shadows or replaces an installed Flock.app, and Scripts/release-build.sh
# stays the only path that produces the signed, notarized release artifact.
#
# Ad-hoc only, always: a dev bundle for same-machine testing has no
# notarization candidate identity to begin with (Apple requires Developer ID),
# and nothing here submits one. spctl is skipped for the same reason
# release-build.sh's ad-hoc branch skips it -- Gatekeeper rejects every
# ad-hoc signature on principle, so the assessment would prove nothing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUTPUT_DIR="build/dev"
DERIVED_DIR="build/dev-derived"
VERIFY=1

usage() {
  cat <<'USAGE'
usage: Scripts/dev-build.sh [options]
  --output <dir>     where Flock-dev.app is written (default: build/dev). A
                     relative path resolves against the repo root, not the
                     directory this was invoked from.
  --skip-verify      build and sign without the codesign checks
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ -n "${2:-}" ] || { echo "dev-build.sh: --output needs a value" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --skip-verify) VERIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dev-build.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in xcodegen xcodebuild codesign ditto; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "dev-build.sh: $tool is required" >&2; exit 1
  }
done

APP_OUT="$OUTPUT_DIR/Flock-dev.app"

Scripts/libghostty.sh --check
xcodegen

mkdir -p "$OUTPUT_DIR"

xcodebuild -scheme Flock-dev -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="-" \
  OTHER_CODE_SIGN_FLAGS="--options runtime" \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Flock-dev.app"
[ -d "$BUILT_APP" ] || {
  echo "dev-build.sh: the build produced no $BUILT_APP" >&2; exit 1
}

# The previous output is destroyed only once there is a new bundle to replace
# it with, so a failed build leaves the last good one on disk.
rm -rf "$APP_OUT"
ditto "$BUILT_APP" "$APP_OUT"

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
echo "dev-build.sh: bundle id $BUNDLE_ID"
echo "dev-build.sh: open \"$APP_OUT\" to launch; rerun this script after an edit and reopen the same path, no install step"
