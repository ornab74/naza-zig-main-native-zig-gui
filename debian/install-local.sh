#!/bin/sh
set -eu
umask 077

command -v zig >/dev/null 2>&1 || { echo "zig 0.15.2 is required" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
zig build -Doptimize=ReleaseSafe

BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.local/share/applications"
mkdir -p "$BIN_DIR" "$APP_DIR"
install -m 700 zig-out/bin/naza-zig "$BIN_DIR/naza-zig"
install -m 600 debian/naza-zig.desktop "$APP_DIR/naza-zig.desktop"
printf 'Installed hardened local GUI launcher. Run: %s gui\n' "$BIN_DIR/naza-zig"
