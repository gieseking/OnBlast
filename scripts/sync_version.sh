#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing VERSION file at $VERSION_FILE" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

PLIST_BUDDY="/usr/libexec/PlistBuddy"

update_plist() {
  local plist_path="$1"
  "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$plist_path"
  "$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist_path"
}

update_plist "$ROOT_DIR/App/Info.plist"
update_plist "$ROOT_DIR/VirtualAudioDevice/AudioServerPlugIn/Info.plist"
update_plist "$ROOT_DIR/VirtualAudioDevice/DriverExtension/Info.plist"
update_plist "$ROOT_DIR/VirtualAudioDevice/XPCService/Info.plist"

echo "Synced version $VERSION (build $BUILD_NUMBER)"
