#!/usr/bin/env bash
# Puts flock's Sparkle signing key into this Mac's login keychain from
# Bitwarden, where it is kept as the secure note named below. Every release
# signs its update feed with this key, and installed copies accept only
# updates signed with it.
#
#   Scripts/restore-signing-key.sh           restore it if this Mac lacks it
#   Scripts/restore-signing-key.sh --verify  check the vault copy matches the
#                                            keychain, changing nothing
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACCOUNT="flock"
ITEM="flock Sparkle update signing key (EdDSA)"
FIELD="private key"
GENERATE_KEYS="$ROOT/Vendor/Sparkle/bin/generate_keys"

fail() { echo "restore-signing-key.sh: $*" >&2; exit 1; }

VERIFY=0
case "${1:-}" in
  "") ;;
  --verify) VERIFY=1 ;;
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) fail "unknown option $1" ;;
esac

"$ROOT/Scripts/fetch-sparkle.sh" >/dev/null
EXPECTED=$(sed -n 's/^ *FLOCK_SPARKLE_PUBLIC_ED_KEY: *"\(.*\)"$/\1/p' "$ROOT/project.yml")
[ -n "$EXPECTED" ] || fail "no FLOCK_SPARKLE_PUBLIC_ED_KEY in project.yml"

in_keychain() { "$GENERATE_KEYS" --account "$ACCOUNT" -p 2>/dev/null; }

if [ "$VERIFY" = 0 ] && [ "$(in_keychain)" = "$EXPECTED" ]; then
  echo "restore-signing-key.sh: this Mac's keychain already has the key ($EXPECTED)"
  exit 0
fi

command -v bw >/dev/null || fail "needs the Bitwarden CLI: brew install bitwarden-cli"
command -v jq >/dev/null || fail "needs jq: brew install jq"
if [ -z "${BW_SESSION:-}" ]; then
  case "$(bw status | jq -r .status)" in
    unauthenticated) fail "log in to Bitwarden first: bw login" ;;
    locked)
      BW_SESSION=$(bw unlock --raw) || fail "could not unlock the vault"
      export BW_SESSION
      ;;
  esac
fi

# A directory rather than two mktemp files: generate_keys -x refuses to write
# over a file that already exists.
KEY_DIR=$(mktemp -d)
VAULT_KEY="$KEY_DIR/vault"
KEYCHAIN_KEY="$KEY_DIR/keychain"
trap 'rm -P -f "$VAULT_KEY" "$KEYCHAIN_KEY"; rmdir "$KEY_DIR"' EXIT
bw get item "$ITEM" | jq -j --arg field "$FIELD" '.fields[] | select(.name == $field) | .value' > "$VAULT_KEY"
[ -s "$VAULT_KEY" ] || fail "no \"$FIELD\" field on the Bitwarden item \"$ITEM\""

if [ "$VERIFY" = 1 ]; then
  [ "$(in_keychain)" = "$EXPECTED" ] || fail "this Mac's keychain has no flock key to compare against"
  "$GENERATE_KEYS" --account "$ACCOUNT" -x "$KEYCHAIN_KEY" >/dev/null
  cmp -s "$VAULT_KEY" "$KEYCHAIN_KEY" || fail "the Bitwarden copy does NOT match this Mac's keychain"
  echo "restore-signing-key.sh: the Bitwarden copy matches this Mac's keychain"
  exit 0
fi

# A different key already under this account would be silently kept by the
# import, so it has to be dealt with by hand rather than papered over.
[ -z "$(in_keychain)" ] || fail "the keychain holds a different key under account $ACCOUNT; remove it in Keychain Access first"

"$GENERATE_KEYS" --account "$ACCOUNT" -f "$VAULT_KEY" >/dev/null
[ "$(in_keychain)" = "$EXPECTED" ] || fail "imported a key whose public half is not the one flock builds carry"
echo "restore-signing-key.sh: restored; the public key matches every flock build ($EXPECTED)"
