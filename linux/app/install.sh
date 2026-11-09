#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
RULES_DIR="${UDEV_RULES_DIR:-/etc/udev/rules.d}"
ID="io.github.FrankieMa77.Qudelix"
ICONS="$PREFIX/share/icons/hicolor"

install -d "$PREFIX/bin" "$PREFIX/share/applications" "$ICONS/scalable/apps" "$ICONS/symbolic/apps" "$PREFIX/share/metainfo"
install -m 0755 "$HERE/qudelix-app" "$PREFIX/bin/qudelix-app"
BIN="$PREFIX/bin/qudelix-app"
PCT_BIN="$(printf '%s' "$BIN" | sed 's/%/%%/g')"
case "$BIN" in
    *[!A-Za-z0-9/._+%-]*)
        QUOTED="$(printf '%s' "$BIN" | sed 's/[\\"`$]/\\&/g; s/\\/\\\\/g; s/%/%%/g')"
        EXEC_LINE="Exec=\"$QUOTED\"" ;;
    *) EXEC_LINE="Exec=$PCT_BIN" ;;
esac
DESKTOP_TMP="$(mktemp)"
trap 'rm -f "$DESKTOP_TMP"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        Exec=*) printf '%s\n' "$EXEC_LINE" ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$HERE/$ID.desktop" > "$DESKTOP_TMP"
install -m 0644 "$DESKTOP_TMP" "$PREFIX/share/applications/$ID.desktop"
install -m 0644 "$HERE/$ID.svg" "$ICONS/scalable/apps/$ID.svg"
install -m 0644 "$HERE/$ID-symbolic.svg" "$ICONS/symbolic/apps/$ID-symbolic.svg"
install -m 0644 "$HERE/$ID.metainfo.xml" "$PREFIX/share/metainfo/$ID.metainfo.xml"
install -d "$RULES_DIR"
install -m 0644 "$HERE/70-qudelix.rules" "$RULES_DIR/70-qudelix.rules"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$ICONS" || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q "$PREFIX/share/applications" || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=hidraw || true
fi

printf 'installed %s\n' "$PREFIX/bin/qudelix-app"
printf 'installed %s\n' "$PREFIX/share/applications/$ID.desktop"
printf 'installed %s\n' "$ICONS/scalable/apps/$ID.svg"
printf 'installed %s\n' "$ICONS/symbolic/apps/$ID-symbolic.svg"
printf 'installed %s\n' "$PREFIX/share/metainfo/$ID.metainfo.xml"
printf 'installed %s\n' "$RULES_DIR/70-qudelix.rules"
printf '\nReconnect the Qudelix 5K so the rule applies, then start Qudelix from the application menu.\n'
printf 'The app needs GTK 4.14 or newer and libadwaita 1.5 or newer.\n'
printf 'The top-bar icon needs a StatusNotifier host (see README.md).\n'
if getent group plugdev >/dev/null 2>&1; then
    printf 'If the device is present but not readable, add your user to the plugdev group,\n'
    printf 'log out and back in, then reconnect the 5K:\n'
    printf '    sudo usermod -aG plugdev "$USER"\n'
else
    printf 'This system has no plugdev group. Create one and add your user to it, or change\n'
    printf 'GROUP in %s to a group you belong to, then reconnect the 5K:\n' "$RULES_DIR/70-qudelix.rules"
    printf '    sudo groupadd plugdev && sudo usermod -aG plugdev "$USER"\n'
fi
