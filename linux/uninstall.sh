#!/bin/sh
set -eu

PREFIX="${PREFIX:-/usr/local}"
RULES_DIR="${UDEV_RULES_DIR:-/etc/udev/rules.d}"

rm -f "$PREFIX/bin/qudelix"
if [ ! -e "$PREFIX/bin/qudelix-app" ]; then
    rm -f "$RULES_DIR/70-qudelix.rules"
fi

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=hidraw || true
fi

printf 'removed qudelix from %s\n' "$PREFIX/bin"
printf 'your settings, preset library and API keys were left in place (see README.md)\n'
