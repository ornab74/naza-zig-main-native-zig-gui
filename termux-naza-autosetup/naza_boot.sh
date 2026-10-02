#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NAZA_BIN="${NAZA_BIN:-$HOME/.naza/naza-zig}"

[ -x "$HERE/naza_unlock.sh" ] || { echo 'ERROR: missing naza_unlock.sh' >&2; exit 1; }
[ -x "$NAZA_BIN" ] || {
    echo "ERROR: NAZA binary not found at $NAZA_BIN" >&2
    echo 'Set NAZA_BIN or install the Android binary into ~/.naza/naza-zig.' >&2
    exit 1
}

"$HERE/naza_unlock.sh"
exec "$NAZA_BIN" tui
