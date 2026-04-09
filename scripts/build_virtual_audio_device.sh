#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/VirtualAudioDevice"
PROJECT_PATH="$PROJECT_DIR/MediaButtonVirtualAudioDevice.xcodeproj"

"$ROOT_DIR/scripts/generate_virtual_audio_project.sh" >/dev/null

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme MediaButtonVirtualAudio \
  -configuration Debug \
  -derivedDataPath "$PROJECT_DIR/.derived" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Built:"
echo "  $PROJECT_DIR/.derived/Build/Products/Debug/MediaButtonVirtualAudioPlugIn.driver"
echo "  $PROJECT_DIR/.derived/Build/Products/Debug/MediaButtonVirtualAudioXPC.xpc"
