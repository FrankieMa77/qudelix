#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build-app.sh | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "could not read VERSION from build-app.sh" >&2
  exit 1
fi
VOLNAME="Qudelix"
APP="${QUDELIX_APP_OUT:-../Qudelix.app}"
OUT_DIR="${QUDELIX_DMG_DIR:-..}"
DMG="$OUT_DIR/Qudelix-${VERSION}.dmg"
export QUDELIX_APP_OUT="$APP"

if [[ -e "$DMG" ]]; then
  echo "$DMG already exists — refusing to overwrite a published artifact." >&2
  echo "Bump VERSION in build-app.sh, or remove it deliberately first." >&2
  exit 1
fi

STAGE=""
BUILD_STAMP=$(mktemp)
trap 'rm -rf "$STAGE" "$BUILD_STAMP"' EXIT
./build-app.sh --universal

BIN="$APP/Contents/MacOS/QudelixBar"
if [[ ! "$BIN" -nt "$BUILD_STAMP" ]]; then
  echo "refusing to package: $BIN was not produced by this run" >&2
  exit 1
fi

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for want in arm64 x86_64; do
  case " $(lipo -archs "$BIN") " in
    *" $want "*) ;;
    *) echo "refusing to package: $want missing from the binary (has: $(lipo -archs "$BIN"))" >&2
       exit 1 ;;
  esac
  if ! vtool -arch "$want" -show-build "$BIN" | awk -v sdk="$SDK_VERSION" '$1 == "sdk" && $2 == sdk { ok = 1 } END { exit !ok }'; then
    echo "refusing to package: the $want slice was not linked against sdk $SDK_VERSION" >&2
    exit 1
  fi
done

BUNDLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$BUNDLED_VERSION" != "$VERSION" ]]; then
  echo "refusing to package: the bundle says $BUNDLED_VERSION, not $VERSION" >&2
  exit 1
fi
codesign --verify --strict "$APP"

STAGE=$(mktemp -d)

cp -R "$APP" "$STAGE/Qudelix.app"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.txt "$STAGE/READ ME FIRST.txt"

osacompile -o "$STAGE/Install Qudelix.app" <<'APPLESCRIPT'
on run
	set myPath to POSIX path of (path to me)
	set srcDir to do shell script "dirname " & quoted form of myPath
	set src to srcDir & "/Qudelix.app"
	try
		do shell script "test -d " & quoted form of src
	on error
		display dialog "Qudelix.app was not found next to this installer. Open the disk image and run the installer from there." buttons {"Close"} default button "Close" with icon stop
		return
	end try
	display dialog "Install Qudelix into the Applications folder?" & return & return & "A copy already there will be replaced." buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel"
	set cmd to "pkill -x QudelixBar; sleep 1; rm -rf /Applications/Qudelix.app && cp -R " & quoted form of src & " /Applications/ && (xattr -dr com.apple.quarantine /Applications/Qudelix.app 2>/dev/null; true)"
	try
		do shell script cmd
	on error
		do shell script cmd with administrator privileges
	end try
	do shell script "open /Applications/Qudelix.app"
	display dialog "Qudelix is installed and running — look for the headphones icon in the menu bar." buttons {"Done"} default button "Done"
end run
APPLESCRIPT

codesign --force --sign - "$STAGE/Install Qudelix.app"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

hdiutil verify -quiet "$DMG"

echo "Built: $(cd "$OUT_DIR" && pwd)/$(basename "$DMG")"
du -h "$DMG" | sed 's/^/  size: /'

DMG_NAME=$(basename "$DMG")
SUM_NAME="${DMG_NAME}.sha256"
( cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > "$SUM_NAME" )
SHA=$(awk '{print $1}' < "$OUT_DIR/$SUM_NAME")

echo "  sha256: $SHA"
echo "  wrote:  $SUM_NAME"

cat <<NOTES

── paste into the GitHub release notes ──────────────────────────────
**SHA-256** \`${DMG_NAME}\`

\`\`\`
${SHA}
\`\`\`

Verify before opening:

\`\`\`
shasum -a 256 ~/Downloads/${DMG_NAME}
\`\`\`
─────────────────────────────────────────────────────────────────────
Upload BOTH as release assets: ${DMG_NAME}, ${SUM_NAME}
NOTES
