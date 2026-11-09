#!/bin/sh
set -eu

PREFIX="${PREFIX:-/usr/local}"
RULES_DIR="${UDEV_RULES_DIR:-/etc/udev/rules.d}"
ID="io.github.FrankieMa77.Qudelix"
ICONS="$PREFIX/share/icons/hicolor"

rm -f "$PREFIX/bin/qudelix-app" \
    "$PREFIX/share/applications/$ID.desktop" \
    "$ICONS/scalable/apps/$ID.svg" \
    "$ICONS/symbolic/apps/$ID-symbolic.svg" \
    "$PREFIX/share/metainfo/$ID.metainfo.xml"
if [ ! -e "$PREFIX/bin/qudelix" ]; then
    rm -f "$RULES_DIR/70-qudelix.rules"
fi

if ! ls "$PREFIX/share/applications"/*.desktop >/dev/null 2>&1; then
    rm -f "$PREFIX/share/applications/mimeinfo.cache"
fi
if [ ! -f "$ICONS/index.theme" ]; then
    rm -f "$ICONS/icon-theme.cache"
elif command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$ICONS" || true
fi
if command -v update-desktop-database >/dev/null 2>&1 && ls "$PREFIX/share/applications"/*.desktop >/dev/null 2>&1; then
    update-desktop-database -q "$PREFIX/share/applications" || true
fi
rmdir "$ICONS/scalable/apps" "$ICONS/scalable" "$ICONS/symbolic/apps" "$ICONS/symbolic" "$ICONS" \
    "$PREFIX/share/metainfo" "$PREFIX/share/applications" 2>/dev/null || true
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=hidraw || true
fi

printf 'removed qudelix-app from %s\n' "$PREFIX"
printf 'your settings, preset library and API keys were left in place (see README.md)\n'
