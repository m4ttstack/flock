#!/usr/bin/env bash
# Writes <release-dir>/appcast.xml: the latest release's feed with a new item
# for <release-dir>/Flock-<version>.zip, signed with the EdDSA key in the
# login keychain (Sparkle account "flock").
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="m4ttstack/flock"
ACCOUNT="flock"
GENERATE_APPCAST="$ROOT/Vendor/Sparkle/bin/generate_appcast"
PREVIOUS=""

usage() {
  cat <<'USAGE'
usage: Scripts/make-appcast.sh [--previous <appcast.xml>] <release-dir> <version>
  Adds Flock-<version>.zip from <release-dir> to the feed published with the
  latest GitHub release and writes the result to <release-dir>/appcast.xml.
  --previous <file>  start from this feed instead of the latest release's
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --previous)
      [ -n "${2:-}" ] || { echo "make-appcast.sh: --previous needs a value" >&2; exit 2; }
      PREVIOUS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "make-appcast.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
RELEASE_DIR="$1"
VERSION="$2"

TAG="v$VERSION"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
ZIP_NAME="Flock-$VERSION.zip"
ZIP="$RELEASE_DIR/$ZIP_NAME"

[ -x "$GENERATE_APPCAST" ] || {
  echo "make-appcast.sh: $GENERATE_APPCAST is missing; run Scripts/fetch-sparkle.sh" >&2; exit 1
}
[ -f "$ZIP" ] || { echo "make-appcast.sh: no $ZIP" >&2; exit 1; }
[ -z "$PREVIOUS" ] || [ -f "$PREVIOUS" ] || { echo "make-appcast.sh: no $PREVIOUS" >&2; exit 1; }

# generate_appcast takes the version from the bundle and the URL from the tag,
# so a zip built without --version would be published under the wrong one.
zipped_version=$(unzip -p "$ZIP" "Flock.app/Contents/Info.plist" \
  | plutil -extract CFBundleShortVersionString raw -o - -)
if [ "$zipped_version" != "$VERSION" ]; then
  echo "make-appcast.sh: $ZIP_NAME holds version $zipped_version, not $VERSION" >&2
  exit 1
fi

# generate_appcast lists every archive in the directory it is given, and the
# release directory also holds this version's disk image (a duplicate version,
# which it refuses) and possibly zips of earlier builds, which it would publish
# under this tag. It gets a directory holding only the new zip.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/flock-appcast.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp "$ZIP" "$STAGE/$ZIP_NAME"

is_http_status() {
  case "$1" in "" | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# A 4xx means there is no previous feed (the first release). Anything else
# aborts: a network failure must not turn into a feed that silently drops
# every earlier release.
if [ -n "$PREVIOUS" ]; then
  cp "$PREVIOUS" "$STAGE/appcast.xml"
  echo "make-appcast.sh: starting from $PREVIOUS"
else
  url="https://github.com/$REPO/releases/latest/download/appcast.xml"
  rc=0
  status=$(curl -sSL -o "$STAGE/appcast.xml" -w '%{http_code}' "$url") || rc=$?
  if [ "$rc" -eq 0 ] && is_http_status "$status" && [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "make-appcast.sh: starting from the latest release's appcast.xml"
  elif is_http_status "$status" && [ "$status" -ge 400 ] && [ "$status" -lt 500 ]; then
    rm -f "$STAGE/appcast.xml"
    echo "make-appcast.sh: no previous appcast.xml (HTTP $status), so this is the first release"
  else
    echo "make-appcast.sh: could not fetch $url (curl exit $rc, HTTP ${status:-none})" >&2
    exit 1
  fi
fi

OLD_URLS=()
if [ -f "$STAGE/appcast.xml" ]; then
  while IFS= read -r old_url; do
    OLD_URLS+=("$old_url")
  done < <(grep -o 'url="[^"]*\.zip"' "$STAGE/appcast.xml" | sed 's/^url="//; s/"$//')
fi

generate_output=$("$GENERATE_APPCAST" \
  --account "$ACCOUNT" \
  --download-url-prefix "$PREFIX" \
  --maximum-deltas 0 \
  --maximum-versions 3 \
  --link "https://github.com/$REPO/releases" \
  "$STAGE" 2>&1) || {
  printf '%s\n' "$generate_output" >&2
  echo "make-appcast.sh: generate_appcast failed" >&2
  exit 1
}
printf '%s\n' "$generate_output"
case "$generate_output" in
  *"does not match"*)
    echo "make-appcast.sh: the keychain key does not match the app's SUPublicEDKey" >&2
    exit 1
    ;;
esac

# Literal substring replacement; a URL is full of regex metacharacters.
literal_replace() {
  local file="$1" old="$2" new="$3"
  awk -v old="$old" -v new="$new" '
    { line = $0; out = ""
      while ((i = index(line, old)) > 0) {
        out = out substr(line, 1, i - 1) new
        line = substr(line, i + length(old))
      }
      print out line
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# --download-url-prefix points every enclosure it touches at this release's
# tag; an item that shipped under an earlier tag has to keep its own URL.
for old_url in "${OLD_URLS[@]+"${OLD_URLS[@]}"}"; do
  name=$(basename "$old_url")
  [ "$name" = "$ZIP_NAME" ] && continue
  [ "$PREFIX$name" = "$old_url" ] && continue
  literal_replace "$STAGE/appcast.xml" "$PREFIX$name" "$old_url"
done

new_enclosure=$(grep '<enclosure' "$STAGE/appcast.xml" | grep -F "url=\"$PREFIX$ZIP_NAME\"" || true)
case "$new_enclosure" in
  "")
    echo "make-appcast.sh: appcast.xml has no enclosure at $PREFIX$ZIP_NAME" >&2
    exit 1
    ;;
  *'sparkle:edSignature="'[A-Za-z0-9+/]*)
    ;;
  *)
    echo "make-appcast.sh: the enclosure for $ZIP_NAME carries no sparkle:edSignature" >&2
    exit 1
    ;;
esac

cp "$STAGE/appcast.xml" "$RELEASE_DIR/appcast.xml"
echo "make-appcast.sh: $RELEASE_DIR/appcast.xml"
