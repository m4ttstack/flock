#!/bin/bash
# Builds herdr X from its upstream tag with patches/herdr/X.patch applied, for
# publishing as a herdr-patch-X release (Scripts/publish-herdr-patch.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION="0.16.0"
ARCH="$(uname -m)"
UPSTREAM="https://github.com/herdrdev/herdr.git"
HERDR_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) HERDR_VERSION="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: Scripts/build-herdr-patch.sh --version X"
      echo "  builds herdr vX with patches/herdr/X.patch into build/herdr-patches/"
      exit 0 ;;
    *) echo "build-herdr-patch: unknown option $1" >&2; exit 2 ;;
  esac
done

[ -n "$HERDR_VERSION" ] || { echo "build-herdr-patch: --version is required" >&2; exit 2; }
PATCH="patches/herdr/$HERDR_VERSION.patch"
[ -f "$PATCH" ] || { echo "build-herdr-patch: no $PATCH" >&2; exit 2; }

case "$(uname -s)" in
  Darwin) ;;
  *) echo "build-herdr-patch: this builds on macOS only ($(uname -s))" >&2; exit 1 ;;
esac
command -v cargo >/dev/null 2>&1 || { echo "build-herdr-patch: cargo is not on PATH (https://rustup.rs)" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || {
  echo "build-herdr-patch: zig $ZIG_VERSION is not on PATH; herdr's build.rs needs it" >&2; exit 1; }
[ "$(zig version)" = "$ZIG_VERSION" ] || {
  echo "build-herdr-patch: zig is $(zig version), herdr's build.rs requires $ZIG_VERSION" >&2; exit 1; }

OUT="build/herdr-patches"
NAME="herdr-mouse-patch-$HERDR_VERSION-$ARCH"
WORK="$(mktemp -d -t flock-herdr-patch)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "build-herdr-patch: cloning herdr v$HERDR_VERSION"
git clone --quiet --depth 1 --branch "v$HERDR_VERSION" "$UPSTREAM" "$WORK/herdr"
TAG_COMMIT="$(git -C "$WORK/herdr" rev-parse HEAD)"
git -C "$WORK/herdr" apply --index "$PWD/$PATCH"

echo "build-herdr-patch: building (this takes a few minutes)"
CARGO_TARGET_DIR="$WORK/target" ZIG="$(command -v zig)" \
  cargo build --release --manifest-path "$WORK/herdr/Cargo.toml"
BUILT="$WORK/target/release/herdr"
[ -x "$BUILT" ] || { echo "build-herdr-patch: cargo build produced no $BUILT" >&2; exit 1; }

# `grep -c`, never `grep -q`: under pipefail `-q` SIGPIPEs `strings` on the
# first match and the pipeline reports failure exactly when the verb is there.
if [ "$(strings "$BUILT" | grep -cF "terminal.mouse_capture")" -eq 0 ]; then
  echo "build-herdr-patch: built binary carries no terminal.mouse_capture verb" >&2
  exit 1
fi
REPORTED="$("$BUILT" --version)"
[ "$REPORTED" = "herdr $HERDR_VERSION" ] || {
  echo "build-herdr-patch: built binary reports '$REPORTED', expected 'herdr $HERDR_VERSION'" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BUILT" "$OUT/$NAME"
chmod 755 "$OUT/$NAME"
cp "$WORK/herdr/LICENSE" "$OUT/$NAME.LICENSE"
cat > "$OUT/$NAME.provenance.txt" <<EOF
# An Apache-2.0 build of herdr $HERDR_VERSION with patches/herdr/$HERDR_VERSION.patch
# from github.com/m4ttstack/flock applied: mouse events and capture state on
# terminal session control. Not made or endorsed by herdr's maintainers.
herdr_version=$HERDR_VERSION
herdr_tag_commit=$TAG_COMMIT
patch_sha256=$(shasum -a 256 "$PATCH" | cut -d' ' -f1)
zig_version=$ZIG_VERSION
arch=$ARCH
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
echo "build-herdr-patch: built $OUT/$NAME ($(du -sh "$OUT/$NAME" | cut -f1))"
