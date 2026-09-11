#!/usr/bin/env bash
# Builds and signs the two-app nest for spike 06 (nested helper launch paths).
# Everything lands under build/ (gitignored). Never touches an installed
# app bundle -- this is a from-scratch scratch build every run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
SIGN_ID="Developer ID Application: Matthew Goodwin (5BF66B3X4V)"

rm -rf "$BUILD"
mkdir -p "$BUILD"

HOST_APP="$BUILD/SpikeHost.app"
HELPER_NAME="SpikeHelper.app"

mkdir -p "$HOST_APP/Contents/MacOS"
swiftc -O "$HERE/Sources/HostApp/main.swift" \
    -o "$HOST_APP/Contents/MacOS/SpikeHost" \
    -framework AppKit -framework ServiceManagement
cp "$HERE/Sources/HostApp/Info.plist" "$HOST_APP/Contents/Info.plist"

build_helper() {
    local dest="$1"
    mkdir -p "$dest/Contents/MacOS"
    swiftc -O -parse-as-library "$HERE/Sources/SpikeHelper/SpikeHelperApp.swift" \
        -o "$dest/Contents/MacOS/SpikeHelper" \
        -framework SwiftUI -framework AppKit
    cp "$HERE/Sources/SpikeHelper/Info.plist" "$dest/Contents/Info.plist"
}

# Contents/Helpers/ -- the nesting the real Paddock host uses; NSWorkspace
# and Process-exec launch the helper from here.
mkdir -p "$HOST_APP/Contents/Helpers"
build_helper "$HOST_APP/Contents/Helpers/$HELPER_NAME"

# Contents/Library/LoginItems/ -- SMAppService.loginItem(identifier:) will
# only find a helper at this exact path; Contents/Helpers is invisible to it.
mkdir -p "$HOST_APP/Contents/Library/LoginItems"
build_helper "$HOST_APP/Contents/Library/LoginItems/$HELPER_NAME"

# Sign inside-out: both nested helper copies first, host last, no --deep
# (deep-signing the host after nested copies are already signed individually
# can clobber those signatures with a blanket one).
codesign --force --options runtime --sign "$SIGN_ID" \
    "$HOST_APP/Contents/Helpers/$HELPER_NAME"
codesign --force --options runtime --sign "$SIGN_ID" \
    "$HOST_APP/Contents/Library/LoginItems/$HELPER_NAME"
codesign --force --options runtime --sign "$SIGN_ID" \
    "$HOST_APP"

echo "Built and signed: $HOST_APP"
