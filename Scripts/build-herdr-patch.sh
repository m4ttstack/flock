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
    --arch) ARCH="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: Scripts/build-herdr-patch.sh --version X [--arch arm64|x86_64]"
      echo "  builds herdr vX with patches/herdr/X.patch into build/herdr-patches/"
      echo "  --arch  the CPU to build for; defaults to this Mac's ($(uname -m))"
      exit 0 ;;
    *) echo "build-herdr-patch: unknown option $1" >&2; exit 2 ;;
  esac
done

[ -n "$HERDR_VERSION" ] || { echo "build-herdr-patch: --version is required" >&2; exit 2; }
case "$ARCH" in
  arm64) RUST_TARGET="aarch64-apple-darwin" ;;
  x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
  *) echo "build-herdr-patch: --arch must be arm64 or x86_64, not $ARCH" >&2; exit 2 ;;
esac
PATCH="patches/herdr/$HERDR_VERSION.patch"
[ -f "$PATCH" ] || { echo "build-herdr-patch: no $PATCH" >&2; exit 2; }

case "$(uname -s)" in
  Darwin) ;;
  *) echo "build-herdr-patch: this builds on macOS only ($(uname -s))" >&2; exit 1 ;;
esac
command -v cargo >/dev/null 2>&1 || { echo "build-herdr-patch: cargo is not on PATH (https://rustup.rs)" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -x "$RUST_TARGET" >/dev/null || {
  echo "build-herdr-patch: the Rust $RUST_TARGET target is missing. Run: rustup target add $RUST_TARGET" >&2; exit 1; }
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

echo "build-herdr-patch: building for $ARCH (this takes a few minutes)"
CARGO_TARGET_DIR="$WORK/target" ZIG="$(command -v zig)" \
  cargo build --release --target "$RUST_TARGET" --manifest-path "$WORK/herdr/Cargo.toml"
BUILT="$WORK/target/$RUST_TARGET/release/herdr"
[ -x "$BUILT" ] || { echo "build-herdr-patch: cargo build produced no $BUILT" >&2; exit 1; }

# x86_64 inlines the verb as 8-byte immediates ("terminal", ".mouse_c",
# "apture"), so it has no whole string there; the middle chunk is absent from
# an unpatched herdr 0.9.5. `grep -c`, never `grep -q`: under pipefail `-q`
# SIGPIPEs `strings` on the first match and the pipeline reports failure
# exactly when the verb is there.
case "$ARCH" in
  x86_64) VERB_MARK=".mouse_c" ;;
  *) VERB_MARK="terminal.mouse_capture" ;;
esac
if [ "$(strings -a -n 8 "$BUILT" | grep -cF -- "$VERB_MARK")" -eq 0 ]; then
  echo "build-herdr-patch: built binary carries no terminal.mouse_capture verb" >&2
  exit 1
fi
[ "$(lipo -archs "$BUILT")" = "$ARCH" ] || {
  echo "build-herdr-patch: built binary is $(lipo -archs "$BUILT"), expected $ARCH" >&2; exit 1; }
# An Intel binary runs here only under Rosetta.
REPORTED="$(arch -"$ARCH" "$BUILT" --version)"
[ "$REPORTED" = "herdr $HERDR_VERSION" ] || {
  echo "build-herdr-patch: built binary reports '$REPORTED', expected 'herdr $HERDR_VERSION'" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BUILT" "$OUT/$NAME"
chmod 755 "$OUT/$NAME"
cp "$WORK/herdr/LICENSE" "$OUT/$NAME.LICENSE"
cat > "$OUT/$NAME.provenance.txt" <<EOF
# An Apache-2.0 build of herdr $HERDR_VERSION with patches/herdr/$HERDR_VERSION.patch
# from github.com/m4ttstack/flock applied: mouse events, capture state and host theme on
# terminal session control. Not made or endorsed by herdr's maintainers.
herdr_version=$HERDR_VERSION
herdr_tag_commit=$TAG_COMMIT
patch_sha256=$(shasum -a 256 "$PATCH" | cut -d' ' -f1)
zig_version=$ZIG_VERSION
arch=$ARCH
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
echo "build-herdr-patch: built $OUT/$NAME ($(du -sh "$OUT/$NAME" | cut -f1))"
