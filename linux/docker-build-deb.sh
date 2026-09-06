#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PLATFORM_ARG=""
if [[ "${1:-}" == --platform ]]; then
  PLATFORM_ARG="--platform $2"
  shift 2
fi

docker build $PLATFORM_ARG -t qudelix-linux-build "$REPO_ROOT/linux"
docker run --rm $PLATFORM_ARG -v "$REPO_ROOT:/src" -v qudelix-build-deb:/build -w /src qudelix-linux-build bash linux/build-deb.sh --scratch-path /build
