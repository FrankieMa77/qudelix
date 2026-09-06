#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/linux"
QUDELIX_BAR="$REPO_ROOT/QudelixBar"

BINARY=""
SCRATCH_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY="$2"
      shift 2
      ;;
    --scratch-path)
      SCRATCH_PATH="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

VERSION=$(grep '^VERSION=' "$QUDELIX_BAR/build-app.sh" | head -1 | cut -d'"' -f2)

if command -v dpkg &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
else
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) ARCH="$(uname -m)" ;;
  esac
fi

STAGE_DIR="/tmp/qudelix-pkg-$$"
trap "rm -rf '$STAGE_DIR'" EXIT

mkdir -p "$STAGE_DIR/usr/bin"
mkdir -p "$STAGE_DIR/lib/udev/rules.d"
mkdir -p "$STAGE_DIR/usr/share/doc/qudelix"
mkdir -p "$STAGE_DIR/DEBIAN"

if [[ -z "$BINARY" ]]; then
  BUILD_CMD="swift build -c release --static-swift-stdlib --product qudelix"
  if [[ -n "$SCRATCH_PATH" ]]; then
    BUILD_CMD="$BUILD_CMD --scratch-path '$SCRATCH_PATH'"
  fi
  cd "$QUDELIX_BAR"
  eval "$BUILD_CMD"
  BINARY="${SCRATCH_PATH:-$QUDELIX_BAR/.build}/release/qudelix"
fi

cp "$BINARY" "$STAGE_DIR/usr/bin/qudelix"
chmod 0755 "$STAGE_DIR/usr/bin/qudelix"

cp "$SCRIPT_DIR/udev/70-qudelix.rules" "$STAGE_DIR/lib/udev/rules.d/"

cp "$REPO_ROOT/LICENSE" "$STAGE_DIR/usr/share/doc/qudelix/copyright"

cat > "$STAGE_DIR/usr/share/doc/qudelix/README.Debian" <<'EOF'
Command-line control for the Qudelix 5K DAC/amp.

After installation, reconnect the Qudelix 5K device so the udev rule applies.
Application log: ~/.local/state/qudelix/qudelix.log
EOF

cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: qudelix
Version: $VERSION
Architecture: $ARCH
Maintainer: FrankieMa77 <alexei.magonov@gmail.com>
Section: sound
Priority: optional
Depends: libc6, libdbus-1-3, udev
Homepage: https://github.com/FrankieMa77/qudelix
Description: Command-line control for the Qudelix 5K DAC/amp
 The qudelix utility provides command-line access to the Qudelix 5K
 digital-to-analog converter and amplifier over USB and Bluetooth.
EOF

cat > "$STAGE_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set +e
if command -v udevadm &>/dev/null; then
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=hidraw
fi
exit 0
EOF
chmod 0755 "$STAGE_DIR/DEBIAN/postinst"

cat > "$STAGE_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/bash
set +e
if command -v udevadm &>/dev/null; then
  udevadm control --reload-rules
fi
exit 0
EOF
chmod 0755 "$STAGE_DIR/DEBIAN/postrm"

mkdir -p "$REPO_ROOT/dist"

if ! command -v dpkg-deb &>/dev/null; then
  echo "dpkg-deb not found. Run this script inside the Docker image from linux/Dockerfile:"
  echo "  docker run --rm -v \$PWD:/src -w /src -v qudelix-build-deb:/build swift:6.2-jammy bash linux/build-deb.sh"
  rm -rf "$STAGE_DIR"
  exit 2
fi

DEB_PATH="$REPO_ROOT/dist/qudelix_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_PATH"

echo "$DEB_PATH"
sha256sum "$DEB_PATH" | awk '{print $1}'
