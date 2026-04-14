#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_PATH="$ROOT_DIR/VirtualAudioDevice/project.yml"
PROJECT_DIR="$ROOT_DIR/VirtualAudioDevice"
PROJECT_PATH="$PROJECT_DIR/OnBlastVirtualAudioDevice.xcodeproj"

if ! command -v xcodegen >/dev/null 2>&1; then
  if [[ -d "$PROJECT_PATH" ]]; then
    echo "xcodegen is not installed; using committed $PROJECT_PATH"
    exit 0
  fi

  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen --spec "$SPEC_PATH" --project "$PROJECT_DIR"

echo "Generated $PROJECT_PATH"
