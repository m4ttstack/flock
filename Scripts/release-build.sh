#!/usr/bin/env bash
# Builds Flock.app in the Release configuration, signed with the hardened
# runtime, into build/release/.
#
# The signing identity is a parameter rather than a constant: a Developer ID is
# a per-machine credential, and a machine without one still has to be able to
# produce a bundle it can launch, which an ad-hoc signature is enough for.
#
# Nothing here notarizes, so two Gatekeeper rejections are expected and pass: a
# Developer ID build rejected for want of notarization, and an ad-hoc build,
# which is not a notarization candidate at all. Any other rejection fails.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY="${FLOCK_SIGN_IDENTITY:-}"
OUTPUT_DIR="build/release"
DERIVED_DIR="build/release-derived"
FORCE_ADHOC=0
VERIFY=1

usage() {
  cat <<'USAGE'
usage: Scripts/release-build.sh [options]
  --identity <name>  codesign identity, as the certificate's common name (the
                     quoted field `security find-identity` prints), not its
                     SHA-1 hash. Default: the machine's sole "Developer ID
                     Application" identity, else ad-hoc.
  --adhoc            sign ad-hoc even when a Developer ID is available
  --output <dir>     where Flock.app is written (default: build/release).
                     A relative path resolves against the repo root, not the
                     directory this was invoked from.
  --skip-verify      build and sign without the codesign/spctl checks
Also read from the environment: FLOCK_SIGN_IDENTITY.
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

for tool in xcodegen xcodebuild codesign ditto security spctl sed; do
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

APP_OUT="$OUTPUT_DIR/Flock.app"

Scripts/libghostty.sh --check
xcodegen

mkdir -p "$OUTPUT_DIR"

xcodebuild -scheme Flock -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Flock.app"
[ -d "$BUILT_APP" ] || {
  echo "release-build.sh: the build produced no $BUILT_APP" >&2; exit 1
}

# The previous output is destroyed only once there is a new bundle to replace
# it with, so a failed build leaves the last good one on disk.
rm -rf "$APP_OUT"
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

  # The identity reaches codesign only as an xcodebuild override. An override
  # that failed to apply leaves the project's ad-hoc default in force, which
  # signs successfully and would otherwise be reported as a Developer ID build.
  if [ "$IDENTITY" = "-" ]; then
    case "$signature" in
      *"Signature=adhoc"*) ;;
      *)
        echo "release-build.sh: asked for an ad-hoc signature, and this bundle carries another" >&2
        exit 1
        ;;
    esac
  else
    case "$signature" in
      *"Authority=$IDENTITY"*) ;;
      *)
        echo "release-build.sh: the signature does not name the requested identity ($IDENTITY)" >&2
        exit 1
        ;;
    esac
  fi

  # Read the CodeDirectory flags field rather than the whole dump: an ad-hoc
  # signature spells the same flag `(adhoc,runtime)`, not `(runtime)`.
  code_flags=$(printf '%s\n' "$signature" \
    | sed -n 's/^CodeDirectory .*flags=[^(]*(\([^)]*\)).*/\1/p')
  case ",$code_flags," in
    *,runtime,*) ;;
    *) echo "release-build.sh: the signature carries no hardened runtime flag" >&2; exit 1 ;;
  esac

  # A bundle with no entitlements reads back empty at status 0, so an empty
  # value is only meaningful once the read itself is known to have succeeded.
  entitlements=$(codesign -d --entitlements - --xml "$APP_OUT" 2>/dev/null) || {
    echo "release-build.sh: could not read the bundle's entitlements" >&2
    exit 1
  }
  case "$entitlements" in
    *get-task-allow*)
      echo "release-build.sh: the binary carries get-task-allow, which notarization refuses" >&2
      exit 1
      ;;
  esac

  echo
  echo "=== spctl -a -vv ==="
  assessment=$(spctl -a -vv "$APP_OUT" 2>&1) && assessed=0 || assessed=$?
  printf '%s\n' "$assessment"
  if [ "$assessed" -ne 0 ]; then
    if [ "$IDENTITY" = "-" ]; then
      echo "release-build.sh: an ad-hoc bundle is never accepted by Gatekeeper and cannot be notarized."
    else
      case "$assessment" in
        *"source=Unnotarized Developer ID"*)
          echo "release-build.sh: rejected for want of notarization, which nothing here does."
          ;;
        *)
          echo "release-build.sh: Gatekeeper rejected this build for something other than notarization" >&2
          exit 1
          ;;
      esac
    fi
  fi
fi

echo
echo "release-build.sh: $APP_OUT"
echo "release-build.sh: identity $IDENTITY"
