#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/FacePromptWatcher.app"
ICON_SOURCE="$ROOT/Assets/FacePromptWatcher.icns"
MODULE_CACHE="$ROOT/.build/module-cache"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$MODULE_CACHE"

swiftc -module-cache-path "$MODULE_CACHE" "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/FacePromptWatcher" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ScreenCaptureKit \
  -framework UserNotifications \
  -framework Vision

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# The checked-in icon is the canonical app asset. Reusing it makes local builds
# deterministic and avoids leaving an unsigned app after an icon conversion failure.
cp "$ICON_SOURCE" "$APP/Contents/Resources/FacePromptWatcher.icns"

codesign --force --sign - \
  --requirements '=designated => identifier "local.codex.FacePromptWatcher"' \
  "$APP"

echo "Built: $APP"
