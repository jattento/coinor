#!/bin/bash

set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_ROOT/../.." && pwd)"
GHOSTTY_ARTIFACT="$SPIKE_ROOT/.build/ghostty-artifact"
XCFRAMEWORK="$GHOSTTY_ARTIFACT/GhosttyKit.xcframework"
RESOURCES="$GHOSTTY_ARTIFACT/Resources"
BUILD_DIR="$SPIKE_ROOT/.build/app"
APP="$BUILD_DIR/CoinorGhosttySpike.app"
EXECUTABLE="$APP/Contents/MacOS/GhosttySpike"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  "$REPO_ROOT/scripts/ghostty/build.sh"
fi
"$REPO_ROOT/scripts/ghostty/verify.sh" >/dev/null

library="$(find "$XCFRAMEWORK" -type f -name '*.a' -print -quit)"
headers="$(find "$XCFRAMEWORK" -type d -name Headers -print -quit)"
[[ -f "$library" ]] || { printf 'missing Ghostty static library\n' >&2; exit 1; }
[[ -d "$headers" ]] || { printf 'missing Ghostty headers\n' >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SPIKE_ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$SPIKE_ROOT/Support/ghostty-spike-command.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/ghostty-spike-command.sh"
ditto "$RESOURCES/ghostty" "$APP/Contents/Resources/ghostty"
ditto "$RESOURCES/terminfo" "$APP/Contents/Resources/terminfo"

sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$SPIKE_ROOT/Sources" -type f -name '*.swift' -print | sort)
xcrun swiftc \
  -swift-version 6 \
  -Xfrontend -strict-concurrency=minimal \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -O \
  -g \
  -I "$headers" \
  "${sources[@]}" \
  "$library" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework Foundation \
  -framework Metal \
  -framework QuartzCore \
  -framework SwiftUI \
  -lstdc++ \
  -o "$EXECUTABLE"

codesign --force --sign - "$APP" >/dev/null

xcrun swiftc \
  -swift-version 6 \
  -target arm64-apple-macos13.0 \
  -framework CoreGraphics \
  -framework Foundation \
  -framework ImageIO \
  "$SPIKE_ROOT/Harnesses/ImageProbe.swift" \
  -o "$BUILD_DIR/image-probe"

printf 'Built %s\n' "$APP"
