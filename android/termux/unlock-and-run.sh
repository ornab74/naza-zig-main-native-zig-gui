#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077
ROOT="${NAZA_ROOT:-$HOME/.local/share/naza-zig}"
KEY_ALIAS="${NAZA_KEYSTORE_ALIAS:-naza-zig-unlock}"
BIN="$ROOT/bin/naza-zig"
[ -x "$BIN" ] || { echo 'Naza is not installed' >&2; exit 1; }
command -v termux-keystore >/dev/null || { echo 'Termux:API keystore unavailable' >&2; exit 1; }
nonce="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
proof="$ROOT/.unlock-proof.$$"
umask 077
trap 'rm -f -- "$proof"' EXIT HUP INT TERM
signature="$(printf '%s' "$nonce" | termux-keystore sign "$KEY_ALIAS" RSA)" || { echo 'Keystore challenge failed' >&2; exit 1; }
[ -n "$signature" ] || { echo 'Keystore returned an empty proof' >&2; exit 1; }
{
  printf 'NAZA-ANDROID-UNLOCK-V1\n'
  printf '%s\n' "$nonce"
  printf '%s\n' "$signature"
} > "$proof"
chmod 600 "$proof"
export NAZA_UNLOCK_PROOF_FILE="$proof"
"$BIN" "$@"
status=$?
exit "$status"
