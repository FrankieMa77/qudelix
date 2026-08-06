#!/bin/zsh
# Builds QudelixBar and assembles Qudelix.app next to the package.
#
#   ./build-app.sh            fast build for the current architecture
#   ./build-app.sh --universal  arm64 + x86_64 (use this for releases)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.2.0"
APP=../Qudelix.app

if [[ "${1:-}" == "--universal" ]]; then
  echo "building universal (arm64 + x86_64)…"
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/QudelixBar
else
  swift build -c release
  BIN=.build/release/QudelixBar
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QudelixBar"
if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: AppIcon.icns missing — run 'swift make-icon.swift'"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Qudelix can use Bluetooth LE to reach the Qudelix 5K.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>The Soundstage and Level features process the Mac's audio output. Nothing is recorded or stored.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Unofficial community app. Not affiliated with Qudelix, Inc.</string>
</dict>
</plist>
PLIST

# --deep is deprecated and unreliable; sign the binary, then the bundle.
codesign --force --sign - "$APP/Contents/MacOS/QudelixBar"
codesign --force --sign - "$APP"
echo "Built: $(cd .. && pwd)/Qudelix.app"
lipo -archs "$APP/Contents/MacOS/QudelixBar" | sed 's/^/  architectures: /'
