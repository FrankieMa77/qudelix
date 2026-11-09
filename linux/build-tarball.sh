#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_ROOT/QudelixBar/.build/release/qudelix"
OUT_DIR="$REPO_ROOT/dist-linux"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "build-tarball.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$REPO_ROOT/QudelixBar/build-app.sh" | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "build-tarball.sh: no VERSION in QudelixBar/build-app.sh" >&2
  exit 1
fi
NAME="qudelix-${VERSION}-linux-$(uname -m)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DIR="$STAGE/$NAME"
mkdir -p "$DIR"

install -m 0755 "$BINARY" "$DIR/qudelix"
strip --strip-unneeded "$DIR/qudelix"
install -m 0644 "$REPO_ROOT/linux/udev/70-qudelix.rules" "$DIR/70-qudelix.rules"
install -m 0644 "$REPO_ROOT/linux/README.md" "$DIR/README.md"
install -m 0644 "$REPO_ROOT/LICENSE" "$DIR/LICENSE"
install -m 0755 "$REPO_ROOT/linux/install.sh" "$DIR/install.sh"
install -m 0755 "$REPO_ROOT/linux/uninstall.sh" "$DIR/uninstall.sh"

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$NAME.tar.gz"
rm -f "$TARBALL"
tar --owner=0 --group=0 --numeric-owner -C "$STAGE" -czf "$TARBALL" "$NAME"
echo "$TARBALL"
sha256sum "$TARBALL"
