#!/bin/bash
# Builds a patched herdr binary from the owner's own herdr checkout and
# vendors it into Sources/Flock/Resources, mirroring Scripts/libghostty.sh's
# vendored-artifact pattern. The artifact is not in git (Sources/Flock/Resources/herdr-mouse-patch-*
# is gitignored): a fresh clone has none, which HerdrMousePatchArtifactLocator
# reads as "unavailable", not a crash.
set -euo pipefail
cd "$(dirname "$0")/.."

HERDR_VERSION="0.9.1"
HERDR_CHECKOUT="${HERDR_CHECKOUT:-$HOME/Documents/GitHub/herdr}"
PATCH_COMMIT="a83af1c8"
ZIG_VERSION="0.16.0"
ARCH="$(uname -m)"
ARTIFACT_NAME="herdr-mouse-patch-$HERDR_VERSION-$ARCH"
ARTIFACT="Sources/Flock/Resources/$ARTIFACT_NAME"
PROVENANCE="Sources/Flock/Resources/$ARTIFACT_NAME.provenance.txt"

CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help)
      echo "usage: Scripts/build-herdr-patch.sh [--check]"
      echo "  --check  report whether the built artifact matches the checkout's current HEAD"
      echo "  HERDR_CHECKOUT overrides the default $HOME/Documents/GitHub/herdr"
      exit 0 ;;
    *) echo "build-herdr-patch: unknown option $1" >&2; exit 2 ;;
  esac
done

if [ "$CHECK" = 1 ]; then
  if [ ! -f "$ARTIFACT" ]; then
    echo "build-herdr-patch: $ARTIFACT is missing. Run: Scripts/build-herdr-patch.sh" >&2
    exit 1
  fi
  BUILT="$(sed -n 's/^herdr_commit=//p' "$PROVENANCE" 2>/dev/null || true)"
  CURRENT="$(git -C "$HERDR_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$BUILT" ]; then
    echo "build-herdr-patch: $ARTIFACT has no $PROVENANCE, so what it holds is unknown." >&2
    exit 1
  elif [ "$BUILT" != "$CURRENT" ]; then
    echo "build-herdr-patch: $ARTIFACT is built from ${BUILT:0:9}, but $HERDR_CHECKOUT's HEAD is ${CURRENT:0:9}." >&2
    exit 1
  fi
  echo "build-herdr-patch: $ARTIFACT is built from ${BUILT:0:9}"
  exit 0
fi

case "$(uname -s)" in
  Darwin) ;;
  *) echo "build-herdr-patch: this builds on macOS only ($(uname -s))" >&2; exit 1 ;;
esac

if [ ! -d "$HERDR_CHECKOUT" ]; then
  echo "build-herdr-patch: no herdr checkout at $HERDR_CHECKOUT (set HERDR_CHECKOUT to point at it)" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "build-herdr-patch: cargo is not on PATH. Install Rust (https://rustup.rs) and retry" >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "build-herdr-patch: zig is not on PATH. herdr vendors ghostty and its build.rs needs" >&2
  echo "                   zig $ZIG_VERSION (https://ziglang.org/download/); this script never installs it" >&2
  exit 1
fi

INSTALLED_ZIG_VERSION="$(zig version)"
if [ "$INSTALLED_ZIG_VERSION" != "$ZIG_VERSION" ]; then
  echo "build-herdr-patch: zig is $INSTALLED_ZIG_VERSION, herdr's build.rs requires $ZIG_VERSION" >&2
  exit 1
fi

CHECKOUT_BRANCH="$(git -C "$HERDR_CHECKOUT" branch --show-current)"
if [ "$CHECKOUT_BRANCH" != "master" ]; then
  echo "build-herdr-patch: $HERDR_CHECKOUT is on '$CHECKOUT_BRANCH', not master. This script reads the" >&2
  echo "                   checkout as-is and never switches its branch; check out master by hand first" >&2
  exit 1
fi

if ! git -C "$HERDR_CHECKOUT" merge-base --is-ancestor "$PATCH_COMMIT" HEAD 2>/dev/null; then
  echo "build-herdr-patch: $HERDR_CHECKOUT's master has no $PATCH_COMMIT (the mouse patch commit)" >&2
  exit 1
fi

CHECKOUT_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$HERDR_CHECKOUT/Cargo.toml" | head -n1)"
if [ "$CHECKOUT_VERSION" != "$HERDR_VERSION" ]; then
  echo "build-herdr-patch: $HERDR_CHECKOUT is herdr $CHECKOUT_VERSION; this script only builds $HERDR_VERSION" >&2
  exit 1
fi

# herdr's build.rs runs `zig build` with current_dir set to vendor/libghostty-vt
# (resolved from CARGO_MANIFEST_DIR), so it writes zig-out/ and its cache THERE
# regardless of CARGO_TARGET_DIR. A clone under $WORK is what actually keeps
# every write off the owner's checkout; CARGO_TARGET_DIR below is set to the
# same scratch tree for the same reason, belt and suspenders.
WORK="$(mktemp -d -t flock-herdr-patch)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "build-herdr-patch: cloning $HERDR_CHECKOUT (read-only; nothing is written back to it)"
git clone --quiet --local "$HERDR_CHECKOUT" "$WORK/herdr"
CHECKOUT_HEAD="$(git -C "$HERDR_CHECKOUT" rev-parse HEAD)"
git -C "$WORK/herdr" checkout --quiet --detach "$CHECKOUT_HEAD"

echo "build-herdr-patch: building herdr $HERDR_VERSION with the mouse patch (this takes a while)"
CARGO_TARGET_DIR="$WORK/target" ZIG="$(command -v zig)" \
  cargo build --release --manifest-path "$WORK/herdr/Cargo.toml"

BUILT="$WORK/target/release/herdr"
[ -x "$BUILT" ] || {
  echo "build-herdr-patch: cargo build produced no $BUILT" >&2
  exit 1
}

# `grep -c`, never `grep -q`, and the reason is this script's own
# `set -o pipefail`: `-q` exits on its first match, which SIGPIPEs `strings`
# for a pipeline status of 141. That made the guard fail precisely WHEN the
# verb was found, so it reported "the patch did not land" on every correct
# build and passed only on a broken one.
if [ "$(strings "$BUILT" | grep -cF "terminal.mouse")" -eq 0 ]; then
  echo "build-herdr-patch: built binary carries no terminal.mouse verb; the patch did not land" >&2
  exit 1
fi

mkdir -p "$(dirname "$ARTIFACT")"
cp "$BUILT" "$ARTIFACT"
chmod 755 "$ARTIFACT"
cp "$HERDR_CHECKOUT/LICENSE" "Sources/Flock/Resources/$ARTIFACT_NAME.LICENSE" 2>/dev/null || true

cat > "$PROVENANCE" <<EOF
# Written by Scripts/build-herdr-patch.sh. This binary is an Apache-2.0
# build of herdr $HERDR_VERSION carrying the changes at $PATCH_COMMIT
# (mouse events and capture state on terminal session control), offered
# upstream in discussion 4058 on 2026-09-13 with no maintainer reply.
herdr_version=$HERDR_VERSION
herdr_commit=$CHECKOUT_HEAD
patch_commit=$(git -C "$WORK/herdr" rev-parse "$PATCH_COMMIT")
zig_version=$ZIG_VERSION
arch=$ARCH
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "build-herdr-patch: built $ARTIFACT ($(du -sh "$ARTIFACT" | cut -f1)) from ${CHECKOUT_HEAD:0:9}"
