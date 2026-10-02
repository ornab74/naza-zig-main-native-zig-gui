#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

printf '\n==============================================================\n'
printf ' NAZA DEVICE UNLOCK\n'
printf '==============================================================\n'
printf 'Lock the Android device now, unlock it with the screen lock,\n'
printf 'then come straight back here.\n\n'

while :; do
    printf 'Type lowercase u after unlocking (q to exit): '
    IFS= read -r answer || exit 1
    case "$answer" in
        u) break ;;
        q) exit 0 ;;
        *) printf 'Please type lowercase u after the device is unlocked.\n' ;;
    esac
done

printf 'Unlock confirmed. Starting NAZA...\n\n'
