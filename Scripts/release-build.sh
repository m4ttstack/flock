#!/usr/bin/env bash
# Builds Paddock.app in the Release configuration, signed with the hardened
# runtime, into build/release/.
#
# The signing identity is a parameter rather than a constant: a Developer ID is
# a per-machine credential, and a machine without one still has to be able to
# produce a bundle it can launch, which an ad-hoc signature is enough for.
#
# Nothing here notarizes. Until something does, `spctl` rejects the result
# ("source=Unnotarized Developer ID") no matter how clean `codesign` is, so the
# Gatekeeper check below reports rather than gates.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY="${PADDOCK_SIGN_IDENTITY:-}"
OUTPUT_DIR="build/release"
DERIVED_DIR="build/release-derived"
FORCE_ADHOC=0
VERIFY=1

usage() {
  cat <<'USAGE'
usage: Scripts/release-build.sh [options]
  --identity <name>  codesign identity (default: the machine's sole
                     "Developer ID Application" identity, else ad-hoc)
  --adhoc            sign ad-hoc even when a Developer ID is available
  --output <dir>     where Paddock.app is written (default: build/release)
  --skip-verify      build and sign without the codesign/spctl checks
Also read from the environment: PADDOCK_SIGN_IDENTITY.
USAGE
}

require_value() {
  [ -n "${2:-}" ] || { echo "release-build.sh: $1 needs a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) require_value "$1" "${2:-}"; IDENTITY="$2"; shift 2 ;;
    --output) require_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --skip-verify) VERIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-build.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in xcodegen xcodebuild codesign ditto; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "release-build.sh: $tool is required" >&2; exit 1
  }
done

if [ "$FORCE_ADHOC" = 1 ]; then
  IDENTITY="-"
elif [ -z "$IDENTITY" ]; then
  # `security` prints one indented line per identity; the common name is the
  # only quoted field on it.
  candidates=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')
  count=$(printf '%s' "$candidates" | grep -c . || true)
  case "$count" in
    0)
      IDENTITY="-"
      echo "release-build.sh: no Developer ID Application identity on this machine; signing ad-hoc"
      ;;
    1) IDENTITY="$candidates" ;;
    *)
      echo "release-build.sh: $count Developer ID identities; name one with --identity" >&2
      printf '%s\n' "$candidates" >&2
      exit 1
      ;;
  esac
fi

# Notarization refuses a signature with no secure timestamp, and an ad-hoc
# signature cannot carry one.
SIGN_FLAGS="--options runtime"
if [ "$IDENTITY" != "-" ]; then
  SIGN_FLAGS="$SIGN_FLAGS --timestamp"
fi

APP_OUT="$OUTPUT_DIR/Paddock.app"

Scripts/libghostty.sh --check
xcodegen

rm -rf "$APP_OUT"
mkdir -p "$OUTPUT_DIR"

xcodebuild -scheme Paddock -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Paddock.app"
[ -d "$BUILT_APP" ] || {
  echo "release-build.sh: the build produced no $BUILT_APP" >&2; exit 1
}

# `ditto`, not `cp`: it is the copy that carries a bundle's extended attributes
# and code signature across intact.
ditto "$BUILT_APP" "$APP_OUT"

if [ "$VERIFY" = 1 ]; then
  echo
  echo "=== codesign -vvv --deep --strict ==="
  codesign -vvv --deep --strict "$APP_OUT"

  echo
  echo "=== codesign -dv --verbose=4 ==="
  signature=$(codesign -dv --verbose=4 "$APP_OUT" 2>&1)
  printf '%s\n' "$signature"
  # Read the CodeDirectory flags field rather than the whole dump: an ad-hoc
  # signature spells the same flag `(adhoc,runtime)`, not `(runtime)`.
  code_flags=$(printf '%s\n' "$signature" \
    | sed -n 's/^CodeDirectory .*flags=[^(]*(\([^)]*\)).*/\1/p')
  case ",$code_flags," in
    *,runtime,*) ;;
    *) echo "release-build.sh: the signature carries no hardened runtime flag" >&2; exit 1 ;;
  esac

  entitlements=$(codesign -d --entitlements - --xml "$APP_OUT" 2>/dev/null || true)
  case "$entitlements" in
    *get-task-allow*)
      echo "release-build.sh: the binary carries get-task-allow, which notarization refuses" >&2
      exit 1
      ;;
  esac

  echo
  echo "=== spctl -a -vv ==="
  set +e
  assessment=$(spctl -a -vv "$APP_OUT" 2>&1)
  assessed=$?
  set -e
  printf '%s\n' "$assessment"
  if [ "$assessed" -ne 0 ]; then
    echo "release-build.sh: Gatekeeper rejects this build; only notarization clears that."
  fi
fi

echo
echo "release-build.sh: $APP_OUT"
echo "release-build.sh: identity $IDENTITY"
