#!/usr/bin/env bash
# Inserts a new <item> entry at the top of docs/appcast.xml. Called from
# the GitHub Actions release workflow after the ZIP is built and signed.
#
# Usage: update-appcast.sh <version> <zip_filename> <byte_length> <sign_update_output>
#
# `sign_update` outputs a string like:
#   sparkle:edSignature="abc..." length="123"
# We extract the sparkle:edSignature attribute from it.

set -euo pipefail

VERSION="${1:?version required, e.g. 1.0.30}"
ZIP_NAME="${2:?zip filename required}"
SIZE="${3:?byte length required}"
SIGN_OUTPUT="${4:?sign_update output required}"

REPO_OWNER="${REPO_OWNER:-aschwarzkopf}"
REPO_NAME="${REPO_NAME:-speaktype}"
MIN_MACOS="${MIN_MACOS:-14.0}"

# Pull the sparkle:edSignature="..." attribute out of sign_update's output.
ED_SIG_ATTR=$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | head -1)
if [[ -z "$ED_SIG_ATTR" ]]; then
  echo "❌ Could not extract sparkle:edSignature from sign_update output." >&2
  echo "Got: $SIGN_OUTPUT" >&2
  exit 1
fi

PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/${ZIP_NAME}"
        length="${SIZE}"
        type="application/octet-stream"
        ${ED_SIG_ATTR} />
    </item>
EOF
)

APPCAST="docs/appcast.xml"
if [[ ! -f "$APPCAST" ]]; then
  echo "❌ $APPCAST not found." >&2
  exit 1
fi

# Insert the new item directly after the <language> tag so latest is at top.
# BSD awk (macOS default) rejects newlines in -v values, so we read the new
# block from a file via getline instead of passing it as a variable.
ITEM_FILE=$(mktemp)
printf '%s\n' "$NEW_ITEM" > "$ITEM_FILE"
TMP=$(mktemp)
awk -v itemfile="$ITEM_FILE" '
  /<language>en<\/language>/ {
    print
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
    next
  }
  { print }
' "$APPCAST" > "$TMP"
mv "$TMP" "$APPCAST"
rm -f "$ITEM_FILE"

echo "✅ Appended v${VERSION} to ${APPCAST}"
