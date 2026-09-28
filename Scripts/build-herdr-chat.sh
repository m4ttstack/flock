#!/bin/bash
# Builds herdr-chat from the mattstack checkout's committed HEAD and vendors it
# into Sources/Flock/Resources, where Flock.app finds it (ChatToolLocator).
# Scripts/release-build.sh runs this on every build. The artifact is
# gitignored: a build without it ships no chat, which the app reads as chat
# absent, not a crash.
#
# Flock Dev does not need this: Scripts/dev-build.sh points it at the
# checkout's own build instead, uncommitted edits included.
set -euo pipefail
cd "$(dirname "$0")/.."

MATTSTACK_CHECKOUT="${MATTSTACK_CHECKOUT:-$HOME/Documents/GitHub/repo-tools}"
CRATE="plugins/herdr-chat"
ARTIFACT="Sources/Flock/Resources/herdr-chat"
PROVENANCE="$ARTIFACT.provenance.txt"

case "${1:-}" in
  "") ;;
  -h|--help)
    echo "usage: Scripts/build-herdr-chat.sh"
    echo "  MATTSTACK_CHECKOUT overrides the default $HOME/Documents/GitHub/repo-tools"
    exit 0 ;;
  *) echo "build-herdr-chat: unknown option $1" >&2; exit 2 ;;
esac

if [ ! -f "$MATTSTACK_CHECKOUT/$CRATE/Cargo.toml" ]; then
  echo "build-herdr-chat: no $CRATE in $MATTSTACK_CHECKOUT (set MATTSTACK_CHECKOUT to point at it)" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "build-herdr-chat: cargo is not on PATH. Install Rust (https://rustup.rs) and retry" >&2
  exit 1
fi

if [ -n "$(git -C "$MATTSTACK_CHECKOUT" status --porcelain -- "$CRATE")" ]; then
  echo "build-herdr-chat: $CRATE has uncommitted changes; they are NOT in this build, which uses HEAD"
fi

# A clone of HEAD, not the working tree, so what ships is a commit the
# provenance file can name, and nothing is written into the owner's checkout.
WORK="$(mktemp -d -t flock-herdr-chat)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CHECKOUT_HEAD="$(git -C "$MATTSTACK_CHECKOUT" rev-parse HEAD)"
echo "build-herdr-chat: cloning $MATTSTACK_CHECKOUT at ${CHECKOUT_HEAD:0:9} (read-only)"
git clone --quiet --local --no-checkout "$MATTSTACK_CHECKOUT" "$WORK/mattstack"
git -C "$WORK/mattstack" checkout --quiet --detach "$CHECKOUT_HEAD"

echo "build-herdr-chat: building herdr-chat"
CARGO_TARGET_DIR="$WORK/target" \
  cargo build --release --locked --manifest-path "$WORK/mattstack/$CRATE/Cargo.toml"

BUILT="$WORK/target/release/herdr-chat"
[ -x "$BUILT" ] || {
  echo "build-herdr-chat: cargo build produced no $BUILT" >&2
  exit 1
}

mkdir -p "$(dirname "$ARTIFACT")"
cp "$BUILT" "$ARTIFACT"
chmod 755 "$ARTIFACT"
cp "$WORK/mattstack/$CRATE/LICENSE" "$ARTIFACT.LICENSE"

cat > "$PROVENANCE" <<EOF
# Written by Scripts/build-herdr-chat.sh.
mattstack_commit=$CHECKOUT_HEAD
herdr_chat_version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$WORK/mattstack/$CRATE/Cargo.toml" | head -n1)
arch=$(uname -m)
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "build-herdr-chat: built $ARTIFACT ($(du -sh "$ARTIFACT" | cut -f1)) from ${CHECKOUT_HEAD:0:9}"
