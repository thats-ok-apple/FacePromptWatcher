#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/FacePromptWatcher.app"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

swiftc "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/FacePromptWatcher" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ScreenCaptureKit \
  -framework UserNotifications \
  -framework Vision

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/FacePromptWatcher.icns" "$APP/Contents/Resources/FacePromptWatcher.icns"

codesign --force --sign - \
  --requirements '=designated => identifier "local.codex.FacePromptWatcher"' \
  "$APP"

echo "Built: $APP"
