#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_ROOT/QudelixBar/.build/release/qudelix-app"
OUT_DIR="$REPO_ROOT/dist-linux"
ID="io.github.FrankieMa77.Qudelix"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "build-app-deb.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$REPO_ROOT/QudelixBar/build-app.sh" | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "build-app-deb.sh: no VERSION in QudelixBar/build-app.sh" >&2
  exit 1
fi
ARCH="$(dpkg --print-architecture)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"
mkdir -p "$PKG/usr/bin" "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/scalable/apps" \
  "$PKG/usr/share/icons/hicolor/symbolic/apps" "$PKG/usr/share/metainfo" "$PKG/usr/share/doc/qudelix-app" "$PKG/DEBIAN"

install -m 0755 "$BINARY" "$PKG/usr/bin/qudelix-app"
strip --strip-unneeded "$PKG/usr/bin/qudelix-app"
install -m 0644 "$REPO_ROOT/linux/app/$ID.desktop" "$PKG/usr/share/applications/$ID.desktop"
install -m 0644 "$REPO_ROOT/linux/app/$ID.svg" "$PKG/usr/share/icons/hicolor/scalable/apps/$ID.svg"
install -m 0644 "$REPO_ROOT/linux/app/$ID-symbolic.svg" "$PKG/usr/share/icons/hicolor/symbolic/apps/$ID-symbolic.svg"
install -m 0644 "$REPO_ROOT/linux/app/$ID.metainfo.xml" "$PKG/usr/share/metainfo/$ID.metainfo.xml"
install -m 0644 "$REPO_ROOT/linux/README.md" "$PKG/usr/share/doc/qudelix-app/README"
install -m 0644 "$REPO_ROOT/LICENSE" "$PKG/usr/share/doc/qudelix-app/copyright"

SHLIBS="$(
  cd "$STAGE"
  mkdir -p debian
  printf 'Source: qudelix-app\n\nPackage: qudelix-app\nArchitecture: any\n' > debian/control
  dpkg-shlibdeps -O -e "$PKG/usr/bin/qudelix-app" 2>/dev/null | sed -n 's/^shlibs:Depends=//p'
)"
if [[ -z "$SHLIBS" ]]; then
  echo "build-app-deb.sh: dpkg-shlibdeps found no shared library dependencies" >&2
  exit 1
fi
SHLIBS="$(printf '%s' "$SHLIBS" | tr ',' '\n' | sed 's/^ *//' | grep -Ev '^(libgtk-4-1|libadwaita-1-0)( |$)' | paste -sd, - | sed 's/,/, /g')"
SHLIBS="$SHLIBS, libgtk-4-1 (>= 4.14), libadwaita-1-0 (>= 1.5)"
DEPENDS="qudelix (>= $VERSION), $SHLIBS"

INSTALLED_KB="$(du -sk "$PKG" | cut -f1)"

cat > "$PKG/DEBIAN/control" <<EOT
Package: qudelix-app
Version: $VERSION
Architecture: $ARCH
Maintainer: FrankieMa77 <55186546+FrankieMa77@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Section: sound
Priority: optional
Depends: $DEPENDS
Recommends: librsvg2-common
Suggests: gnome-shell-extension-appindicator
Homepage: https://github.com/FrankieMa77/qudelix
Description: desktop app for the Qudelix 5K
 Qudelix shows the Qudelix 5K DAC and amplifier and changes its settings:
 volume, DAC filter, the parametric EQ, the device's preset slots, a local
 preset library, AutoEq import and the battery level. It has a window and a
 top-bar tray menu. The USB link is the supported one; the Bluetooth link is
 included but untested. The qudelix package supplies the udev rule.
EOT

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/qudelix-app_${VERSION}_${ARCH}.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "$DEB"
sha256sum "$DEB"
