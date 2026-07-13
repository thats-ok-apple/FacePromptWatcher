#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/FacePromptWatcher.app"
ICONSET="$ROOT/dist/FacePromptWatcher.iconset"
ICON_PNG="$ROOT/dist/FacePromptWatcher-icon.png"
ICON_RENDERER="$ROOT/dist/render-icon"

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

# Generate the macOS icon bundle from the repository's Swift renderer.
swiftc "$ROOT/Tools/render_icon.swift" \
  -o "$ICON_RENDERER" \
  -framework AppKit
"$ICON_RENDERER" "$ICON_PNG"

mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/FacePromptWatcher.icns"

codesign --force --sign - \
  --requirements '=designated => identifier "local.codex.FacePromptWatcher"' \
  "$APP"

echo "Built: $APP"
