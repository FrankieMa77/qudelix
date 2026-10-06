#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.4.6"
APP="${QUDELIX_APP_OUT:-../Qudelix.app}"
APP_PARENT="$(dirname "$APP")"

REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD -- . 2>/dev/null; then REVISION="${REVISION}+"; fi

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINK_SDK=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")

if [[ "${1:-}" == "--universal" ]]; then
  echo "building universal (arm64 + x86_64)…"
  BUILD=(-c release --arch arm64 --arch x86_64 "${LINK_SDK[@]}")
  WANT_ARCHS=(arm64 x86_64)
else
  BUILD=(-c release "${LINK_SDK[@]}")
  WANT_ARCHS=()
fi

verify_binary() {
  local bin="$1" arch build
  shift
  if [[ ! -f "$bin" ]]; then
    echo "refusing to package: $bin was not produced by this build" >&2
    return 1
  fi
  if [[ -n "$(find Sources Package.swift -type f -name '*.swift' -newer "$bin" -print -quit)" ]]; then
    echo "refusing to package: $bin is older than the sources, so it is not built from them" >&2
    return 1
  fi
  for arch in "$@"; do
    if [[ " $(lipo -archs "$bin") " != *" $arch "* ]]; then
      echo "refusing to package: $arch is missing from $bin (has: $(lipo -archs "$bin"))" >&2
      return 1
    fi
  done
  for arch in $(lipo -archs "$bin"); do
    build="$(vtool -arch "$arch" -show-build "$bin")"
    if ! print -r -- "$build" | awk -v sdk="$SDK_VERSION" '$1 == "sdk" && $2 == sdk { ok = 1 } END { exit !ok }'; then
      echo "refusing to package: the $arch slice of $bin was not linked against sdk $SDK_VERSION" >&2
      return 1
    fi
    if ! print -r -- "$build" | awk '$1 == "minos" && $2 == "14.0" { ok = 1 } END { exit !ok }'; then
      echo "refusing to package: the $arch slice of $bin does not target macOS 14.0" >&2
      return 1
    fi
  done
}

uuids() {
  dwarfdump --uuid "$1" | awk '{ print $2 }' | sort
}

swift build "${BUILD[@]}"
BIN="$(swift build "${BUILD[@]}" --show-bin-path | tail -1)/QudelixBar"
verify_binary "$BIN" "${WANT_ARCHS[@]}"

mkdir -p "$APP_PARENT"
STAGE="$(mktemp -d .build/stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$(basename "$APP")"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$BIN" "$NEW/Contents/MacOS/QudelixBar"
if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$NEW/Contents/Resources/AppIcon.icns"
else
  echo "warning: AppIcon.icns missing — run 'swift make-icon.swift'"
fi

cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>QudelixBar</string>
    <key>CFBundleIdentifier</key>          <string>com.qudelixbar.app</string>
    <key>CFBundleName</key>                <string>Qudelix</string>
    <key>CFBundleDisplayName</key>         <string>Qudelix</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleVersion</key>             <string>${VERSION}</string>
    <key>QBSourceRevision</key>            <string>${REVISION}</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Qudelix can use Bluetooth LE to reach the Qudelix 5K.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Stream quality detection, Soundstage and Level analyse the Mac's audio output in memory. Nothing is recorded or stored.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Unofficial community app. Not affiliated with Qudelix, Inc.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign - "$NEW/Contents/MacOS/QudelixBar"
codesign --force --options runtime --sign - "$NEW"

verify_binary "$NEW/Contents/MacOS/QudelixBar" "${WANT_ARCHS[@]}"
if [[ "$(uuids "$BIN")" != "$(uuids "$NEW/Contents/MacOS/QudelixBar")" ]]; then
  echo "refusing to install: the bundled binary is not the one this build produced" >&2
  exit 1
fi
codesign --verify --strict "$NEW"

if [[ -e "$APP" ]]; then
  mv "$APP" "$STAGE/previous"
fi
if ! mv "$NEW" "$APP"; then
  if [[ -e "$STAGE/previous" ]]; then
    mv "$STAGE/previous" "$APP"
  fi
  echo "could not move the new bundle into place at $APP" >&2
  exit 1
fi

echo "Built: $(cd "$APP_PARENT" && pwd)/$(basename "$APP")"
lipo -archs "$APP/Contents/MacOS/QudelixBar" | sed 's/^/  architectures: /'
