#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
RELEASE_DIR="$ROOT_DIR/.dist/releases/OnBlast-$VERSION"
ARCHIVE_PATH="$ROOT_DIR/.dist/releases/OnBlast-$VERSION-macOS.zip"

"$ROOT_DIR/scripts/build_app.sh"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cp -R "$ROOT_DIR/.dist/OnBlast.app" "$RELEASE_DIR/"
cp "$ROOT_DIR/docs/INSTALL.md" "$RELEASE_DIR/INSTALL.md"

rm -f "$ARCHIVE_PATH"
(
  cd "$ROOT_DIR/.dist/releases"
  ditto -c -k --sequesterRsrc --keepParent "OnBlast-$VERSION" "$(basename "$ARCHIVE_PATH")"
)

echo "Packaged release archive:"
echo "  $ARCHIVE_PATH"
