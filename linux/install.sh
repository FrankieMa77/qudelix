#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
RULES_DIR="${UDEV_RULES_DIR:-/etc/udev/rules.d}"

install -d "$PREFIX/bin"
install -m 0755 "$HERE/qudelix" "$PREFIX/bin/qudelix"
install -d "$RULES_DIR"
install -m 0644 "$HERE/70-qudelix.rules" "$RULES_DIR/70-qudelix.rules"

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=hidraw || true
fi

printf 'installed %s\n' "$PREFIX/bin/qudelix"
printf 'installed %s\n' "$RULES_DIR/70-qudelix.rules"
printf '\nReconnect the Qudelix 5K so the rule applies.\n'
printf 'If qudelix still reports the device as present but not readable, the session\n'
printf 'did not grant access through logind or elogind (uaccess).\n'
if getent group plugdev >/dev/null 2>&1; then
    printf 'Add your user to the plugdev group, log out and back in, then reconnect the 5K:\n'
    printf '    sudo usermod -aG plugdev "$USER"\n'
else
    printf 'This system has no plugdev group. Create one and add your user to it, or change\n'
    printf 'GROUP in %s to a group you belong to, then reconnect the 5K:\n' "$RULES_DIR/70-qudelix.rules"
    printf '    sudo groupadd plugdev && sudo usermod -aG plugdev "$USER"\n'
fi
