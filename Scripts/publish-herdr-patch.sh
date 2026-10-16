#!/bin/bash
# Signs a built herdr patch and publishes it as the herdr-patch-X pre-release
# that HerdrMousePatchCatalog points at. Always a pre-release: Sparkle reads
# releases/latest/download/appcast.xml, and a full release here could become
# "latest" and break every installed copy's update feed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: Scripts/publish-herdr-patch.sh X" >&2; exit 2; }
REPO="m4ttstack/flock"
TAG="herdr-patch-$VERSION"
NAME="herdr-mouse-patch-$VERSION-arm64"
DIR="build/herdr-patches"
for f in "$NAME" "$NAME.provenance.txt" "$NAME.LICENSE"; do
  [ -f "$DIR/$f" ] || { echo "publish-herdr-patch: no $DIR/$f; run Scripts/build-herdr-patch.sh --version $VERSION" >&2; exit 1; }
done
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "publish-herdr-patch: $TAG already exists; a published patch is never replaced" >&2
  exit 1
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n1)"
[ -n "$IDENTITY" ] || { echo "publish-herdr-patch: no Developer ID Application identity" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIR/$NAME"
codesign --verify --strict "$DIR/$NAME"

SHA="$(shasum -a 256 "$DIR/$NAME" | cut -d' ' -f1)"
printf '%s  %s\n' "$SHA" "$NAME" > "$DIR/$NAME.sha256"

NOTES="An Apache-2.0 build of herdr $VERSION with [patches/herdr/$VERSION.patch](https://github.com/$REPO/blob/main/patches/herdr/$VERSION.patch) applied, so herdr's terminal session control reports mouse capture to Flock. Flock downloads and verifies this file itself from Settings; it is not made or endorsed by herdr's maintainers.

SHA-256: \`$SHA\`"
gh release create "$TAG" -R "$REPO" --prerelease --title "herdr $VERSION mouse patch" --notes "$NOTES" \
  "$DIR/$NAME" "$DIR/$NAME.sha256" "$DIR/$NAME.provenance.txt" "$DIR/$NAME.LICENSE"

echo "HerdrMousePatchEntry(version: \"$VERSION\", sha256: \"$SHA\"),"
