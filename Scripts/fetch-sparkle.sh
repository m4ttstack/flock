#!/usr/bin/env bash
# Vendors Sparkle into Vendor/Sparkle/: Sparkle.xcframework, which the Flock
# target links and embeds, and bin/, the tools (generate_appcast and friends)
# the release scripts sign the update feed with.
#
# A pinned, sha-verified download rather than a Swift package: resolving a
# package's binary artifact hangs on hosted GitHub runners.
#
# Idempotent: an archive whose stamp already records the pinned sha, and whose
# unpacked output is still present, is neither downloaded nor unpacked again.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="2.9.6"
BASE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION"
XCFRAMEWORK_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
TOOLS_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
DEST="Vendor/Sparkle"

for tool in curl shasum ditto tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "fetch-sparkle.sh: $tool is required" >&2; exit 1
  }
done

mkdir -p "$DEST"
# Inside DEST so the final moves are renames on one volume.
WORK=$(mktemp -d "$DEST/.fetch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# download <url> <sha256> <file>
download() {
  echo "fetch-sparkle.sh: downloading $1"
  curl -fsSL --retry 3 -o "$3" "$1"
  local actual
  actual=$(shasum -a 256 "$3" | cut -d' ' -f1)
  if [ "$actual" != "$2" ]; then
    echo "fetch-sparkle.sh: sha256 mismatch for $1" >&2
    echo "  expected $2" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

# is_current <stamp> <sha256> <output path>
is_current() {
  [ -e "$3" ] && [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]
}

XCFRAMEWORK_STAMP="$DEST/.xcframework.sha256"
if is_current "$XCFRAMEWORK_STAMP" "$XCFRAMEWORK_SHA256" "$DEST/Sparkle.xcframework"; then
  echo "fetch-sparkle.sh: Sparkle.xcframework $VERSION already present"
else
  download "$BASE_URL/Sparkle-for-Swift-Package-Manager.zip" "$XCFRAMEWORK_SHA256" "$WORK/spm.zip"
  mkdir "$WORK/spm"
  ditto -x -k "$WORK/spm.zip" "$WORK/spm"
  [ -d "$WORK/spm/Sparkle.xcframework" ] || {
    echo "fetch-sparkle.sh: the archive holds no Sparkle.xcframework" >&2; exit 1
  }
  rm -rf "$DEST/Sparkle.xcframework" "$XCFRAMEWORK_STAMP"
  mv "$WORK/spm/Sparkle.xcframework" "$DEST/Sparkle.xcframework"
  printf '%s\n' "$XCFRAMEWORK_SHA256" > "$XCFRAMEWORK_STAMP"
  echo "fetch-sparkle.sh: $DEST/Sparkle.xcframework"
fi

TOOLS_STAMP="$DEST/.tools.sha256"
if is_current "$TOOLS_STAMP" "$TOOLS_SHA256" "$DEST/bin/generate_appcast"; then
  echo "fetch-sparkle.sh: Sparkle tools $VERSION already present"
else
  download "$BASE_URL/Sparkle-$VERSION.tar.xz" "$TOOLS_SHA256" "$WORK/tools.tar.xz"
  mkdir "$WORK/tools"
  tar -xJf "$WORK/tools.tar.xz" -C "$WORK/tools" ./bin ./LICENSE
  [ -x "$WORK/tools/bin/generate_appcast" ] || {
    echo "fetch-sparkle.sh: the archive holds no bin/generate_appcast" >&2; exit 1
  }
  rm -rf "$DEST/bin" "$DEST/LICENSE" "$TOOLS_STAMP"
  mv "$WORK/tools/bin" "$DEST/bin"
  mv "$WORK/tools/LICENSE" "$DEST/LICENSE"
  printf '%s\n' "$TOOLS_SHA256" > "$TOOLS_STAMP"
  echo "fetch-sparkle.sh: $DEST/bin"
fi
