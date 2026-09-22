#!/usr/bin/env bash
# Builds Flock.app in the Release configuration, signed with the hardened
# runtime, into build/release/, then notarizes and staples it and packages it
# twice: Flock-<version>.zip, the archive Sparkle updates installed copies
# from, and Flock-<version>.dmg, the first-install download.
#
# The signing identity is a parameter rather than a constant: a Developer ID is
# a per-machine credential, and a machine without one still has to be able to
# produce a bundle it can launch, which an ad-hoc signature is enough for.
#
# An ad-hoc build is never a notarization candidate (Apple requires a Developer
# ID signature) and is expected to fail spctl for that reason alone. A
# Developer-ID build with no notarization credential configured skips
# notarization with an explanation rather than failing the build, since the
# artifact it already produced is real and correctly signed, just not yet
# submitted.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY="${FLOCK_SIGN_IDENTITY:-}"
OUTPUT_DIR="build/release"
DERIVED_DIR="build/release-derived"
FORCE_ADHOC=0
VERIFY=1
NOTARIZE=1
BUILD_DMG=1
VERSION=""
NOTARY_PROFILE="${FLOCK_NOTARY_PROFILE:-flock-notary}"

usage() {
  cat <<'USAGE'
usage: Scripts/release-build.sh [options]
  --version <X.Y.Z>  the version this build ships as (CFBundleShortVersionString
                     and the artifact names). Required for a release; without
                     it the build keeps project.yml's MARKETING_VERSION. The
                     build number is always the commit count at HEAD.
  --identity <name>  codesign identity, as the certificate's common name (the
                     quoted field `security find-identity` prints), not its
                     SHA-1 hash. Default: the machine's sole "Developer ID
                     Application" identity, else ad-hoc.
  --adhoc            sign ad-hoc even when a Developer ID is available
  --output <dir>     where Flock.app is written (default: build/release).
                     A relative path resolves against the repo root, not the
                     directory this was invoked from.
  --skip-verify      build and sign without the codesign/spctl checks
  --skip-notarize    build and sign without submitting for notarization
  --skip-dmg         stop after the .app; build no installer disk image
  --notary-profile <name>  keychain profile name passed to
                     `notarytool --keychain-profile` (default: flock-notary)
Also read from the environment: FLOCK_SIGN_IDENTITY, FLOCK_NOTARY_PROFILE.
An App Store Connect API key takes over from the keychain profile when all
three of FLOCK_NOTARY_KEY_ID, FLOCK_NOTARY_KEY_ISSUER and FLOCK_NOTARY_KEY_PATH
are set.
USAGE
}

require_value() {
  [ -n "${2:-}" ] || { echo "release-build.sh: $1 needs a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --identity) require_value "$1" "${2:-}"; IDENTITY="$2"; shift 2 ;;
    --output) require_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --skip-verify) VERIFY=0; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --skip-dmg) BUILD_DMG=0; shift ;;
    --notary-profile) require_value "$1" "${2:-}"; NOTARY_PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-build.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in git xcodegen xcodebuild codesign ditto security spctl sed xcrun; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "release-build.sh: $tool is required" >&2; exit 1
  }
done

if [ -n "$VERSION" ] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release-build.sh: --version must be X.Y.Z, got $VERSION" >&2
  exit 2
fi

# Sparkle orders updates by CFBundleVersion, so it has to grow with every
# release; releases are cut from main, whose commit count only grows.
BUILD_NUMBER=$(git rev-list --count HEAD)
VERSION_OVERRIDES=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
[ -n "$VERSION" ] && VERSION_OVERRIDES+=(MARKETING_VERSION="$VERSION")

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
Scripts/fetch-sparkle.sh
xcodegen

# The vendored herdr patch is a Mach-O sitting in Resources, and Xcode treats
# anything there as a resource: it seals the bytes into the bundle's signature
# but never signs the file itself. Notarization rejects the whole app for it,
# with all three of no Developer ID, no secure timestamp and no hardened
# runtime against that one path.
#
# Signed here, BEFORE the build copies it in, so the bundle seals a binary
# that is already correct. Signing it afterwards would mean re-signing the app
# to repair the seal, and that re-sign drops the entitlements xcodebuild
# applied unless they are extracted and handed back... a step that fails
# silently and is only visible much later.
#
# Idempotent by --force: the artifact is gitignored and rebuilt by
# Scripts/build-herdr-patch.sh, so it arrives unsigned each time it is made.
for patch in Sources/Flock/Resources/herdr-mouse-patch-*; do
  case "$patch" in
    *.txt|*.LICENSE|*'*') continue ;;
  esac
  [ -f "$patch" ] || continue
  echo
  echo "=== codesign (bundled herdr patch) ==="
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $SIGN_FLAGS "$patch"
  codesign -dv --verbose=2 "$patch" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true
done

# Sparkle's helpers ship ad-hoc signed, which notarization rejects, and
# Xcode's sign-on-copy re-signs only the framework's own binary, never the
# code nested in it. Signed in the vendored copy for the same reason as the
# herdr patch: the build then embeds and seals code that is already correct.
# Downloader.xpc keeps its entitlements, as in Sparkle's own re-signing steps;
# the rest are signed without theirs.
SPARKLE_VERSIONED="Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B"
SPARKLE_HELPERS="XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app"
echo
echo "=== codesign (Sparkle helpers) ==="
for helper in $SPARKLE_HELPERS; do
  preserve=""
  [ "$helper" = "XPCServices/Downloader.xpc" ] && preserve="--preserve-metadata=entitlements"
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $SIGN_FLAGS $preserve "$SPARKLE_VERSIONED/$helper"
done

mkdir -p "$OUTPUT_DIR"

xcodebuild -scheme Flock -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DIR" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  "${VERSION_OVERRIDES[@]}" \
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

INFO_PLIST="$APP_OUT/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
if [ -n "$VERSION" ] && [ "$APP_VERSION" != "$VERSION" ]; then
  echo "release-build.sh: asked for version $VERSION, and the bundle says $APP_VERSION" >&2
  exit 1
fi
if [ "$APP_BUILD" != "$BUILD_NUMBER" ]; then
  echo "release-build.sh: asked for build $BUILD_NUMBER, and the bundle says $APP_BUILD" >&2
  exit 1
fi

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

  # A release without its feed installs fine and never updates again.
  for key in SUFeedURL SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1 || {
      echo "release-build.sh: the bundle carries no $key, so it could never update" >&2
      exit 1
    }
  done

  if [ "$IDENTITY" != "-" ]; then
    for helper in $SPARKLE_HELPERS; do
      helper_signature=$(codesign -dv --verbose=2 \
        "$APP_OUT/Contents/Frameworks/Sparkle.framework/Versions/B/$helper" 2>&1)
      case "$helper_signature" in
        *"Authority=$IDENTITY"*) ;;
        *)
          echo "release-build.sh: Sparkle's $helper is not signed by $IDENTITY" >&2
          exit 1
          ;;
      esac
    done
  fi

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

if [ "$NOTARIZE" = 1 ] && [ "$VERIFY" = 0 ]; then
  echo
  echo "release-build.sh: --skip-verify also skips notarization (it depends on the hardened-runtime/entitlements checks above)."
  NOTARIZE=0
fi

if [ "$NOTARIZE" = 1 ] && [ "$IDENTITY" = "-" ]; then
  echo
  echo "release-build.sh: an ad-hoc signature cannot be notarized (Apple requires a Developer ID signer); skipping."
  NOTARIZE=0
fi

if [ "$NOTARIZE" = 1 ]; then
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  if [ -n "${FLOCK_NOTARY_KEY_ID:-}" ] && [ -n "${FLOCK_NOTARY_KEY_ISSUER:-}" ] && [ -n "${FLOCK_NOTARY_KEY_PATH:-}" ]; then
    NOTARY_AUTH_ARGS=(--key "$FLOCK_NOTARY_KEY_PATH" --key-id "$FLOCK_NOTARY_KEY_ID" --issuer "$FLOCK_NOTARY_KEY_ISSUER")
  fi

  ZIP_PATH="$OUTPUT_DIR/Flock-notarization-submission.zip"
  rm -f "$ZIP_PATH"
  # notarytool wants a zip/dmg/pkg, never a raw .app directory.
  ditto -c -k --keepParent "$APP_OUT" "$ZIP_PATH"

  echo
  echo "=== xcrun notarytool submit ==="
  set +e
  submit_output=$(xcrun notarytool submit "$ZIP_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait 2>&1)
  submit_status=$?
  set -e
  printf '%s\n' "$submit_output"
  rm -f "$ZIP_PATH"

  # notarytool's own exit code for an unknown keychain profile (69, checked
  # against this machine) is not documented as stable, so the message text is
  # the primary match and the exit code only a secondary signal.
  if printf '%s' "$submit_output" | grep -q "No Keychain password item found" \
     || { [ "$submit_status" -ne 0 ] && printf '%s' "$submit_output" | grep -qi "credentials"; }; then
    cat <<EOF

release-build.sh: no notarization credential configured ($NOTARY_PROFILE); skipping notarization and stapling.
This build is signed with Developer ID and the hardened runtime, but WILL
trip Gatekeeper's "cannot verify" block on any machine that has not already
chosen to trust this Developer ID. Set up ONE of the following, then rerun:

  App-specific password in a keychain profile (simplest for one machine):
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your Apple ID email>" \\
      --team-id 5BF66B3X4V \\
      --password "<an app-specific password from appleid.apple.com>"

  App Store Connect API key (works headless, e.g. CI):
    export FLOCK_NOTARY_KEY_ID="<key id>"
    export FLOCK_NOTARY_KEY_ISSUER="<issuer id>"
    export FLOCK_NOTARY_KEY_PATH="<path to the downloaded AuthKey_XXXX.p8>"
EOF
  elif [ "$submit_status" -ne 0 ]; then
    echo "release-build.sh: notarytool submit failed for a reason other than a missing credential" >&2
    exit 1
  else
    case "$submit_output" in
      *"status: Accepted"*) ;;
      *)
        submission_id=$(printf '%s' "$submit_output" | sed -n 's/^[[:space:]]*id: \(.*\)/\1/p' | head -1)
        echo "release-build.sh: notarization did not report Accepted" >&2
        [ -n "$submission_id" ] && xcrun notarytool log "$submission_id" "${NOTARY_AUTH_ARGS[@]}"
        exit 1
        ;;
    esac

    echo
    echo "=== xcrun stapler staple ==="
    xcrun stapler staple "$APP_OUT"

    echo
    echo "=== xcrun stapler validate ==="
    xcrun stapler validate "$APP_OUT"

    echo
    echo "=== spctl -a -vv (post-notarization) ==="
    assessment=$(spctl -a -vv "$APP_OUT" 2>&1) && assessed=0 || assessed=$?
    printf '%s\n' "$assessment"
    if [ "$assessed" -ne 0 ]; then
      echo "release-build.sh: notarized and stapled, but spctl still rejects the bundle" >&2
      exit 1
    fi
  fi
fi

# ── the update archive ───────────────────────────────────────────────────────
#
# Made from the stapled app, so an installed copy that updates from it gets
# the app's own ticket. Scripts/make-appcast.sh signs it into the feed.
UPDATE_ZIP="$OUTPUT_DIR/Flock-$APP_VERSION.zip"
rm -f "$UPDATE_ZIP"
echo
echo "=== ditto (update archive) ==="
ditto -c -k --sequesterRsrc --keepParent "$APP_OUT" "$UPDATE_ZIP"

# ── the installer disk image ─────────────────────────────────────────────────
#
# Built after the app is stapled, never before: a user who drags the app out
# and runs it on a machine that is offline needs the app's OWN ticket, and
# stapling the image does not put one there.
#
# The drag gesture is the point of it, not decoration. macOS applies App
# Translocation to a quarantined app the user has not explicitly moved, and a
# real drag from this window to Applications is the gesture that counts as
# moving it. A clean-room run watched flock launch translocated from
# /private/var after a Finder copy driven over Apple Events, which is not the
# same gesture and cannot stand in for it.
if [ "$BUILD_DMG" = 1 ]; then
  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "release-build.sh: create-dmg not found (brew install create-dmg), skipping the disk image" >&2
  else
    DMG_PATH="$OUTPUT_DIR/Flock-$APP_VERSION.dmg"
    DMG_STAGE="$OUTPUT_DIR/dmg-stage"
    DMG_ART="$OUTPUT_DIR/dmg-art"
    rm -rf "$DMG_STAGE" "$DMG_ART" "$DMG_PATH"
    # A folder holding the app and nothing else: create-dmg copies the whole
    # source directory, so a stray file here ships inside the image.
    mkdir -p "$DMG_STAGE"
    ditto "$APP_OUT" "$DMG_STAGE/$(basename "$APP_OUT")"
    swift Scripts/make-dmg-background.swift "$DMG_ART" >/dev/null

    echo
    echo "=== create-dmg ==="
    # Window and icon geometry must match Scripts/make-dmg-background.swift,
    # which draws the arrow between these two positions.
    create-dmg \
      --volname "flock" \
      --background "$DMG_ART/dmg-background.png" \
      --window-pos 200 120 \
      --window-size 540 380 \
      --icon-size 128 \
      --icon "$(basename "$APP_OUT")" 140 190 \
      --app-drop-link 400 190 \
      --no-internet-enable \
      "$DMG_PATH" "$DMG_STAGE"

    rm -rf "$DMG_STAGE" "$DMG_ART"

    echo
    echo "=== codesign (disk image) ==="
    codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

    if [ "$NOTARIZE" = 1 ] && [ -n "${NOTARY_AUTH_ARGS+x}" ]; then
      echo
      echo "=== xcrun notarytool submit (disk image) ==="
      set +e
      dmg_output=$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait 2>&1)
      dmg_status=$?
      set -e
      printf '%s\n' "$dmg_output"
      case "$dmg_output" in
        *"status: Accepted"*)
          echo
          echo "=== xcrun stapler staple (disk image) ==="
          # The image carries its own ticket, so the download itself clears
          # Gatekeeper on a machine with no network.
          xcrun stapler staple "$DMG_PATH"
          xcrun stapler validate "$DMG_PATH"
          ;;
        *)
          echo "release-build.sh: the disk image was not notarized; $DMG_PATH is signed but unstapled" >&2
          [ "$dmg_status" -ne 0 ] && exit 1
          ;;
      esac
    fi
  fi
fi

echo
echo "release-build.sh: $APP_OUT (version $APP_VERSION, build $APP_BUILD)"
echo "release-build.sh: $UPDATE_ZIP"
[ -f "${DMG_PATH:-}" ] && echo "release-build.sh: $DMG_PATH"
echo "release-build.sh: identity $IDENTITY"
