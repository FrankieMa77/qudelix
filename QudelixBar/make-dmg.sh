#!/bin/zsh
# Builds a universal Qudelix.app and packages it as a distributable DMG.
#   ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.2.0"
VOLNAME="Qudelix"
DMG="../Qudelix-${VERSION}.dmg"

./build-app.sh --universal

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R ../Qudelix.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.txt "$STAGE/READ ME FIRST.txt"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

echo "Built: $(cd .. && pwd)/$(basename "$DMG")"
du -h "$DMG" | sed 's/^/  size: /'

# The build is signed ad-hoc, so macOS cannot tell a downloader who produced it
# and an attacker who swaps the release asset can re-sign theirs just as easily.
# The published checksum is the only thing that distinguishes this build from
# that one, so a release is not finished until the hash below is on the release
# page. The sidecar is written in `shasum -c` format so it can be checked with
# one command.
DMG_NAME=$(basename "$DMG")
SUM_NAME="${DMG_NAME}.sha256"
( cd .. && shasum -a 256 "$DMG_NAME" > "$SUM_NAME" )
SHA=$(awk '{print $1}' < "../$SUM_NAME")

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
