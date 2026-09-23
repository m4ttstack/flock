#!/usr/bin/env bash
# Publishes v<version> to GitHub Releases: Flock-<version>.dmg (the first
# install), Flock-<version>.zip (what installed copies update from) and
# appcast.xml (the feed they poll, served from the latest release), with
# docs/releases/<version>.md as the release's notes.
#
# Run after Scripts/release-build.sh --version <version> and
# Scripts/make-appcast.sh on a clean checkout of the commit they were built
# from. Everything is checked before anything is published: a release, once
# installed copies have seen its feed, cannot be taken back.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPO="m4ttstack/flock"
RELEASE_DIR="build/release"

usage() {
  cat <<'USAGE'
usage: Scripts/publish-release.sh [--dir <release-dir>] <version>
  --dir <dir>  where the three assets are (default: build/release)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ -n "${2:-}" ] || { echo "publish-release.sh: --dir needs a value" >&2; exit 2; }
      RELEASE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "publish-release.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { usage >&2; exit 2; }
VERSION="$1"
TAG="v$VERSION"

fail() { echo "publish-release.sh: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must be X.Y.Z, got $VERSION"

for tool in gh git plutil unzip ditto xcrun; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

DMG="$RELEASE_DIR/Flock-$VERSION.dmg"
ZIP="$RELEASE_DIR/Flock-$VERSION.zip"
APPCAST="$RELEASE_DIR/appcast.xml"
NOTES="docs/releases/$VERSION.md"
for asset in "$DMG" "$ZIP" "$APPCAST"; do
  [ -f "$asset" ] || fail "missing $asset"
done
[ -s "$NOTES" ] || fail "no release notes at $NOTES"

[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"

HEAD_SHA=$(git rev-parse HEAD)
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists locally"
fi
remote_tag=$(git ls-remote --tags origin "refs/tags/$TAG") || fail "could not list origin's tags"
[ -z "$remote_tag" ] || fail "tag $TAG already exists on origin"

# gh creates the tag on GitHub at --target, so the commit has to be there.
gh api "repos/$REPO/commits/$HEAD_SHA" --silent 2>/dev/null \
  || fail "HEAD ($HEAD_SHA) is not on GitHub; push it first"

# The build number is the commit count, so a zip whose count differs from
# HEAD's was built from some other commit than the one being tagged.
zipped_value() {
  unzip -p "$ZIP" "Flock.app/Contents/Info.plist" | plutil -extract "$1" raw -o - -
}
zipped_version=$(zipped_value CFBundleShortVersionString)
zipped_build=$(zipped_value CFBundleVersion)
[ "$zipped_version" = "$VERSION" ] || fail "$ZIP holds version $zipped_version, not $VERSION"
head_build=$(git rev-list --count HEAD)
[ "$zipped_build" = "$head_build" ] \
  || fail "$ZIP is build $zipped_build, and HEAD is build $head_build; rebuild from HEAD"

# Sparkle refuses an update that is not signed like the installed app, and
# Gatekeeper blocks a download that carries no ticket, so an ad-hoc or
# unnotarized build must never be published.
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG is not notarized and stapled"
UNPACKED=$(mktemp -d "${TMPDIR:-/tmp}/flock-publish.XXXXXX")
trap 'rm -rf "$UNPACKED"' EXIT
ditto -x -k "$ZIP" "$UNPACKED"
xcrun stapler validate "$UNPACKED/Flock.app" >/dev/null \
  || fail "the app in $ZIP is not notarized and stapled"

feed_entry=$(grep -F "releases/download/$TAG/Flock-$VERSION.zip" "$APPCAST" || true)
case "$feed_entry" in
  *'sparkle:edSignature="'[A-Za-z0-9+/]*) ;;
  *) fail "$APPCAST has no signed item for $TAG; run Scripts/make-appcast.sh $RELEASE_DIR $VERSION" ;;
esac

grep -q 'sparkle:format="markdown"' "$APPCAST" \
  || fail "$APPCAST carries no release notes; run Scripts/make-appcast.sh $RELEASE_DIR $VERSION"

# Read before this release's own tag exists, so it names the one before.
PREVIOUS_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)
BODY="$UNPACKED/notes.md"
cp "$NOTES" "$BODY"
if [ -n "$PREVIOUS_TAG" ]; then
  printf '\n**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREVIOUS_TAG" "$TAG" >> "$BODY"
fi

# --latest: installed copies find the feed through releases/latest.
gh release create "$TAG" "$DMG" "$ZIP" "$APPCAST" \
  --repo "$REPO" \
  --target "$HEAD_SHA" \
  --title "Flock $VERSION" \
  --notes-file "$BODY" \
  --latest

echo "publish-release.sh: https://github.com/$REPO/releases/tag/$TAG"
