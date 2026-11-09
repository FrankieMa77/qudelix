#!/bin/sh
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ID="io.github.FrankieMa77.Qudelix"
failures=0

check() {
    if eval "$2"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n' "$1"
        failures=$((failures + 1))
    fi
}

stage_cli() {
    rm -rf "$WORK/cli"
    mkdir -p "$WORK/cli"
    cp "$REPO/linux/install.sh" "$REPO/linux/uninstall.sh" "$REPO/linux/udev/70-qudelix.rules" "$WORK/cli/"
    printf '#!/bin/sh\n' > "$WORK/cli/qudelix"
    chmod 755 "$WORK/cli/qudelix"
}

stage_app() {
    rm -rf "$WORK/app"
    mkdir -p "$WORK/app"
    cp "$REPO"/linux/app/install.sh "$REPO"/linux/app/uninstall.sh "$REPO"/linux/app/"$ID"* "$WORK/app/"
    cp "$REPO/linux/udev/70-qudelix.rules" "$WORK/app/"
    printf '#!/bin/sh\n' > "$WORK/app/qudelix-app"
    chmod 755 "$WORK/app/qudelix-app"
}

fresh() {
    PREFIX="$WORK/prefix"
    UDEV_RULES_DIR="$WORK/rules"
    export PREFIX UDEV_RULES_DIR
    rm -rf "$PREFIX" "$UDEV_RULES_DIR"
    stage_cli
    stage_app
}

RULE='[ -e "$UDEV_RULES_DIR/70-qudelix.rules" ]'

fresh
sh "$WORK/cli/install.sh" >/dev/null
sh "$WORK/app/install.sh" >/dev/null
sh "$WORK/cli/uninstall.sh" >/dev/null
check "cli uninstall keeps the rule while the app is installed" "$RULE"
check "cli uninstall removes the cli binary" '[ ! -e "$PREFIX/bin/qudelix" ]'
check "cli uninstall leaves the app binary" '[ -x "$PREFIX/bin/qudelix-app" ]'
sh "$WORK/app/uninstall.sh" >/dev/null
check "app uninstall removes the rule once the cli is gone" '[ ! -e "$UDEV_RULES_DIR/70-qudelix.rules" ]'

fresh
sh "$WORK/app/install.sh" >/dev/null
sh "$WORK/cli/install.sh" >/dev/null
sh "$WORK/app/uninstall.sh" >/dev/null
check "app uninstall keeps the rule while the cli is installed" "$RULE"
check "app uninstall removes the app binary" '[ ! -e "$PREFIX/bin/qudelix-app" ]'
check "app uninstall leaves the cli binary" '[ -x "$PREFIX/bin/qudelix" ]'
sh "$WORK/cli/uninstall.sh" >/dev/null
check "cli uninstall removes the rule once the app is gone" '[ ! -e "$UDEV_RULES_DIR/70-qudelix.rules" ]'

fresh
sh "$WORK/cli/install.sh" >/dev/null
sh "$WORK/cli/uninstall.sh" >/dev/null
check "cli alone: uninstall removes the rule" '[ ! -e "$UDEV_RULES_DIR/70-qudelix.rules" ]'

fresh
sh "$WORK/app/install.sh" >/dev/null
sh "$WORK/app/uninstall.sh" >/dev/null
check "app alone: uninstall removes the rule" '[ ! -e "$UDEV_RULES_DIR/70-qudelix.rules" ]'
check "app alone: nothing is left under the prefix" '[ -z "$(find "$PREFIX" -type f 2>/dev/null)" ]'

fresh
sh "$WORK/app/install.sh" >/dev/null
check "installed launcher runs the binary under the prefix" \
    'grep -qx "Exec=$PREFIX/bin/qudelix-app" "$PREFIX/share/applications/$ID.desktop"'
check "installed launcher keeps every other line" \
    '[ "$(grep -vc "^Exec=" "$PREFIX/share/applications/$ID.desktop")" = "$(grep -vc "^Exec=" "$REPO/linux/app/$ID.desktop")" ]'
check "the shipped launcher is left untouched" 'grep -qx "Exec=qudelix-app" "$WORK/app/$ID.desktop"'

fresh
PREFIX="$WORK/with space"
export PREFIX
sh "$WORK/app/install.sh" >/dev/null
check "a prefix with a space is quoted in the launcher" \
    'grep -qx "Exec=\"$PREFIX/bin/qudelix-app\"" "$PREFIX/share/applications/$ID.desktop"'

fresh
PREFIX="$WORK"'/a$b%c"d'
export PREFIX
sh "$WORK/app/install.sh" >/dev/null
EXPECTED="$(printf '%s' "$WORK" | sed 's/%/%%/g')"'/a\\$b%%c\\"d/bin/qudelix-app'
check "a prefix with a dollar, percent and quote is escaped in the launcher" \
    'grep -qxF "Exec=\"$EXPECTED\"" "$PREFIX/share/applications/$ID.desktop"'

fresh
PREFIX="$WORK/100%"
export PREFIX
sh "$WORK/app/install.sh" >/dev/null
check "a percent in the prefix is doubled even when nothing else needs quoting" \
    'grep -qxF "Exec=$WORK/100%%/bin/qudelix-app" "$PREFIX/share/applications/$ID.desktop"'

if [ "$failures" -ne 0 ]; then
    printf '%s failed\n' "$failures"
    exit 1
fi
printf 'all passed\n'
