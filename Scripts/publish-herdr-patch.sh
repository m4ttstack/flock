#!/bin/bash
# Signs a built herdr patch and publishes it to the herdr-patch-X pre-release
# that HerdrMousePatchCatalog points at, one architecture per run: the first
# creates the release, a later one adds its own assets to it. Always a
# pre-release: Sparkle reads
# releases/latest/download/appcast.xml, and a full release here could become
# "latest" and break every installed copy's update feed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
ARCH="${2:-$(uname -m)}"
[ -n "$VERSION" ] || { echo "usage: Scripts/publish-herdr-patch.sh X [arm64|x86_64]" >&2; exit 2; }
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "publish-herdr-patch: the architecture must be arm64 or x86_64, not $ARCH" >&2; exit 2 ;;
esac
REPO="m4ttstack/flock"
TAG="herdr-patch-$VERSION"
NAME="herdr-mouse-patch-$VERSION-$ARCH"
DIR="build/herdr-patches"
for f in "$NAME" "$NAME.provenance.txt" "$NAME.LICENSE"; do
  [ -f "$DIR/$f" ] || { echo "publish-herdr-patch: no $DIR/$f; run Scripts/build-herdr-patch.sh --version $VERSION --arch $ARCH" >&2; exit 1; }
done
EXISTING=0
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  EXISTING=1
  if gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' | grep -qx "$NAME"; then
    echo "publish-herdr-patch: $TAG already carries $NAME; a published patch is never replaced" >&2
    exit 1
  fi
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n1)"
[ -n "$IDENTITY" ] || { echo "publish-herdr-patch: no Developer ID Application identity" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIR/$NAME"
codesign --verify --strict "$DIR/$NAME"

SHA="$(shasum -a 256 "$DIR/$NAME" | cut -d' ' -f1)"
printf '%s  %s\n' "$SHA" "$NAME" > "$DIR/$NAME.sha256"

ASSETS=("$DIR/$NAME" "$DIR/$NAME.sha256" "$DIR/$NAME.provenance.txt" "$DIR/$NAME.LICENSE")
if [ "$EXISTING" = 1 ]; then
  gh release upload "$TAG" -R "$REPO" "${ASSETS[@]}"
else
  NOTES="An Apache-2.0 build of herdr $VERSION with [patches/herdr/$VERSION.patch](https://github.com/$REPO/blob/main/patches/herdr/$VERSION.patch) applied, so herdr's terminal session control reports mouse capture to Flock. Flock downloads and verifies this file itself from Settings; it is not made or endorsed by herdr's maintainers. Each architecture's SHA-256 is in its \`.sha256\` asset."
  gh release create "$TAG" -R "$REPO" --prerelease --title "herdr $VERSION mouse patch" --notes "$NOTES" "${ASSETS[@]}"
fi

echo "$ARCH SHA-256 for HerdrMousePatchRelease(version: \"$VERSION\", ...): $SHA"
