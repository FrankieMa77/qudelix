#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="qudelix-app-build"

mkdir -p "$REPO_ROOT/dist-linux"
rm -f "$REPO_ROOT"/dist-linux/qudelix-app_*.deb "$REPO_ROOT"/dist-linux/qudelix-app-[0-9]*.tar.gz
docker build -t "$IMAGE" -f "$REPO_ROOT/linux/Dockerfile.app" "$REPO_ROOT/linux"
docker run --rm \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e QUDELIX_APP=1 \
  -v "$REPO_ROOT:/src" \
  -v qudelix-app-build:/build \
  -w /src \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    cd /src/QudelixBar
    swift build -c release --static-swift-stdlib --product qudelix-app --scratch-path /build
    cd /src
    bash linux/build-app-deb.sh --binary /build/release/qudelix-app --out /src/dist-linux
    bash linux/build-app-tarball.sh --binary /build/release/qudelix-app --out /src/dist-linux
    chown -R "$HOST_UID:$HOST_GID" /src/dist-linux
  '
ls -l "$REPO_ROOT/dist-linux"
