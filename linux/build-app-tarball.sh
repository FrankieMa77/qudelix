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
    *) echo "build-app-tarball.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/linux/VERSION")"
if [[ -z "$VERSION" ]]; then
  echo "build-app-tarball.sh: no version in linux/VERSION" >&2
  exit 1
fi
NAME="qudelix-app-${VERSION}-linux-$(uname -m)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DIR="$STAGE/$NAME"
mkdir -p "$DIR"

install -m 0755 "$BINARY" "$DIR/qudelix-app"
strip --strip-unneeded "$DIR/qudelix-app"
install -m 0644 "$REPO_ROOT/linux/app/$ID.desktop" "$DIR/$ID.desktop"
install -m 0644 "$REPO_ROOT/linux/app/$ID.svg" "$DIR/$ID.svg"
install -m 0644 "$REPO_ROOT/linux/app/$ID-symbolic.svg" "$DIR/$ID-symbolic.svg"
install -m 0644 "$REPO_ROOT/linux/app/$ID.metainfo.xml" "$DIR/$ID.metainfo.xml"
install -m 0644 "$REPO_ROOT/linux/udev/70-qudelix.rules" "$DIR/70-qudelix.rules"
install -m 0644 "$REPO_ROOT/linux/README.md" "$DIR/README.md"
install -m 0644 "$REPO_ROOT/LICENSE" "$DIR/LICENSE"
install -m 0755 "$REPO_ROOT/linux/app/install.sh" "$DIR/install.sh"
install -m 0755 "$REPO_ROOT/linux/app/uninstall.sh" "$DIR/uninstall.sh"

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$NAME.tar.gz"
rm -f "$TARBALL"
tar --owner=0 --group=0 --numeric-owner -C "$STAGE" -czf "$TARBALL" "$NAME"
echo "$TARBALL"
sha256sum "$TARBALL"
