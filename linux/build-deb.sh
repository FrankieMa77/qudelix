#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_ROOT/QudelixBar/.build/release/qudelix"
OUT_DIR="$REPO_ROOT/dist-linux"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "build-deb.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$REPO_ROOT/QudelixBar/build-app.sh" | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "build-deb.sh: no VERSION in QudelixBar/build-app.sh" >&2
  exit 1
fi
ARCH="$(dpkg --print-architecture)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"
mkdir -p "$PKG/usr/bin" "$PKG/usr/lib/udev/rules.d" "$PKG/usr/share/doc/qudelix" "$PKG/DEBIAN"

install -m 0755 "$BINARY" "$PKG/usr/bin/qudelix"
strip --strip-unneeded "$PKG/usr/bin/qudelix"
install -m 0644 "$REPO_ROOT/linux/udev/70-qudelix.rules" "$PKG/usr/lib/udev/rules.d/70-qudelix.rules"
install -m 0644 "$REPO_ROOT/linux/README.md" "$PKG/usr/share/doc/qudelix/README"
install -m 0644 "$REPO_ROOT/LICENSE" "$PKG/usr/share/doc/qudelix/copyright"

INSTALLED_KB="$(du -sk "$PKG" | cut -f1)"

cat > "$PKG/DEBIAN/control" <<EOT
Package: qudelix
Version: $VERSION
Architecture: $ARCH
Maintainer: FrankieMa77 <55186546+FrankieMa77@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Section: sound
Priority: optional
Depends: libc6, libstdc++6, libcurl4, libdbus-1-3, udev
Homepage: https://github.com/FrankieMa77/qudelix
Description: command-line control for the Qudelix 5K over USB
 qudelix reads and changes the Qudelix 5K DAC and amplifier: volume, DAC
 filter, the parametric EQ, the device's preset slots, a local preset library
 and AutoEq import. The USB link is the supported one; the Bluetooth link is
 included but untested.
EOT

for script in postinst postrm; do
  cat > "$PKG/DEBIAN/$script" <<'EOT'
#!/bin/sh
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=hidraw >/dev/null 2>&1 || true
fi
exit 0
EOT
  chmod 0755 "$PKG/DEBIAN/$script"
done

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/qudelix_${VERSION}_${ARCH}.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "$DEB"
sha256sum "$DEB"
