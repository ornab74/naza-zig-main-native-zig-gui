#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEST="$HOME/.naza"
mkdir -p "$DEST"
chmod 700 "$DEST"
cp "$HERE/naza_unlock.sh" "$DEST/naza_unlock.sh"
cp "$HERE/naza_boot.sh" "$DEST/naza_boot.sh"
chmod 700 "$DEST/naza_unlock.sh" "$DEST/naza_boot.sh"

if [ ! -f "$HOME/.bashrc" ] || ! grep -q 'BEGIN NAZA AUTO-START' "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'BASHRC'
# === BEGIN NAZA AUTO-START ===
if [ -z "${NAZA_STARTED:-}" ] && [ -z "${SSH_CLIENT:-}" ] && [ -z "${TMUX:-}" ]; then
    export NAZA_STARTED=1
    if [ -x "$HOME/.naza/naza_boot.sh" ]; then
        "$HOME/.naza/naza_boot.sh"
    fi
fi
alias naza='"$HOME/.naza/naza_boot.sh"'
# === END NAZA AUTO-START ===
BASHRC
fi

echo 'NAZA Termux auto-start installed. Open a new Termux session to test it.'
