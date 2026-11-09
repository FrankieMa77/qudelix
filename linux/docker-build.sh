#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="qudelix-linux-build"

mkdir -p "$REPO_ROOT/dist-linux"
rm -f "$REPO_ROOT"/dist-linux/qudelix_*.deb "$REPO_ROOT"/dist-linux/qudelix-[0-9]*.tar.gz
docker build -t "$IMAGE" "$REPO_ROOT/linux"
docker run --rm \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$REPO_ROOT:/src" \
  -v qudelix-linux-build:/build \
  -w /src \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    cd /src/QudelixBar
    swift build -c release --static-swift-stdlib --product qudelix --scratch-path /build
    cd /src
    bash linux/build-deb.sh --binary /build/release/qudelix --out /src/dist-linux
    bash linux/build-tarball.sh --binary /build/release/qudelix --out /src/dist-linux
    chown -R "$HOST_UID:$HOST_GID" /src/dist-linux
  '
ls -l "$REPO_ROOT/dist-linux"
