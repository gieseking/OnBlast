#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OnBlast"
SELF_TEST_HELPER_NAME="VirtualMicSelfTestHelper"
CAPTURE_HELPER_NAME="VirtualMicCaptureHelper"
BUILD_CONFIGURATION="release"
PRODUCT_PATH="$ROOT_DIR/.build/$BUILD_CONFIGURATION/$APP_NAME"
SELF_TEST_HELPER_PATH="$ROOT_DIR/.build/$BUILD_CONFIGURATION/$SELF_TEST_HELPER_NAME"
CAPTURE_HELPER_PATH="$ROOT_DIR/.build/$BUILD_CONFIGURATION/$CAPTURE_HELPER_NAME"
APP_BUNDLE="$ROOT_DIR/.dist/$APP_NAME.app"
APP_IDENTIFIER="com.gieseking.OnBlast"
APP_ICON="$ROOT_DIR/App/AppIcon.icns"
VIRTUAL_AUDIO_PRODUCT_DIR="$ROOT_DIR/VirtualAudioDevice/.derived/Build/Products/Debug"
VIRTUAL_AUDIO_DRIVER_PRODUCT="$VIRTUAL_AUDIO_PRODUCT_DIR/OnBlastVirtualAudioPlugIn.driver"
VIRTUAL_AUDIO_XPC_PRODUCT="$VIRTUAL_AUDIO_PRODUCT_DIR/OnBlastVirtualAudioXPC.xpc"
VIRTUAL_AUDIO_RESOURCE_DIR="$APP_BUNDLE/Contents/Resources/VirtualAudioDriver"

cd "$ROOT_DIR"
swift "$ROOT_DIR/scripts/generate_app_icon.swift"
"$ROOT_DIR/scripts/build_virtual_audio_device.sh"
swift build -c "$BUILD_CONFIGURATION"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PRODUCT_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SELF_TEST_HELPER_PATH" "$APP_BUNDLE/Contents/Resources/$SELF_TEST_HELPER_NAME"
chmod +x "$APP_BUNDLE/Contents/Resources/$SELF_TEST_HELPER_NAME"
cp "$CAPTURE_HELPER_PATH" "$APP_BUNDLE/Contents/Resources/$CAPTURE_HELPER_NAME"
chmod +x "$APP_BUNDLE/Contents/Resources/$CAPTURE_HELPER_NAME"
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$VIRTUAL_AUDIO_RESOURCE_DIR"
cp -R "$VIRTUAL_AUDIO_DRIVER_PRODUCT" "$VIRTUAL_AUDIO_RESOURCE_DIR/"
cp -R "$VIRTUAL_AUDIO_XPC_PRODUCT" "$VIRTUAL_AUDIO_RESOURCE_DIR/"

if command -v codesign >/dev/null 2>&1; then
  codesign --remove-signature "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
  codesign --force --sign - --timestamp=none --identifier "$APP_IDENTIFIER" "$APP_BUNDLE"
fi

echo "Built $APP_BUNDLE"
