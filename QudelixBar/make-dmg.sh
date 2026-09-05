#!/bin/zsh
# Builds a universal Qudelix.app and packages it as a distributable DMG.
#   ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

# Read from the app build rather than kept in step by hand. These two drifted
# — this said 1.2.0 while the app said 1.3.0 — and because the DMG name and its
# checksum sidecar are derived from it, a release run would have rebuilt the
# published 1.2.0 artifact from newer sources and rewritten its .sha256 to
# match. For an ad-hoc-signed download the published checksum is the only thing
# that distinguishes a genuine release from a substituted one, so silently
# reissuing different bytes under a shipped version is the worst outcome this
# script has available.
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build-app.sh | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "could not read VERSION from build-app.sh" >&2
  exit 1
fi
VOLNAME="Qudelix"
DMG="../Qudelix-${VERSION}.dmg"

# Refuse to stand on a release that already exists. Bump the version instead.
if [[ -e "$DMG" ]]; then
  echo "$DMG already exists — refusing to overwrite a published artifact." >&2
  echo "Bump VERSION in build-app.sh, or remove it deliberately first." >&2
  exit 1
fi

./build-app.sh --universal

ARCHS="$(lipo -archs ../Qudelix.app/Contents/MacOS/QudelixBar)"
for want in arm64 x86_64; do
  case " $ARCHS " in
    *" $want "*) ;;
    *) echo "refusing to package: $want missing from the binary (has: $ARCHS)" >&2
       exit 1 ;;
  esac
done

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
