#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command ditto
require_command git
require_command xcodebuild

zig="$("$SCRIPT_DIR/bootstrap.sh")"
/usr/bin/xcrun --sdk macosx metal --version >/dev/null 2>&1 || \
  die "Xcode Metal Toolchain is required; install it with: xcodebuild -downloadComponent MetalToolchain"

rm -rf \
  "$GHOSTTY_INSTALL_PREFIX" \
  "$GHOSTTY_ARTIFACT_ROOT" \
  "$GHOSTTY_SOURCE/macos/GhosttyKit.xcframework"
mkdir -p \
  "$GHOSTTY_INSTALL_PREFIX" \
  "$GHOSTTY_ARTIFACT_ROOT" \
  "$GHOSTTY_ZIG_CACHE" \
  "$GHOSTTY_ZIG_GLOBAL_CACHE"

(
  cd "$GHOSTTY_SOURCE"
  "$zig" build \
    --prefix "$GHOSTTY_INSTALL_PREFIX" \
    --cache-dir "$GHOSTTY_ZIG_CACHE" \
    --global-cache-dir "$GHOSTTY_ZIG_GLOBAL_CACHE" \
    -Doptimize=ReleaseFast \
    -Dversion-string="$GHOSTTY_VERSION" \
    -Dxcframework-target=native \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Demit-exe=false \
    -Demit-themes=true \
    -Demit-terminfo=true \
    -Di18n=false \
    -Dsentry=false \
    --summary all
)

[[ -d "$GHOSTTY_SOURCE/macos/GhosttyKit.xcframework" ]] || \
  die "Ghostty build did not produce GhosttyKit.xcframework"
[[ -d "$GHOSTTY_INSTALL_PREFIX/share/ghostty" ]] || \
  die "Ghostty build did not produce runtime resources"
[[ -d "$GHOSTTY_INSTALL_PREFIX/share/terminfo" ]] || \
  die "Ghostty build did not produce compiled terminfo"

ditto "$GHOSTTY_SOURCE/macos/GhosttyKit.xcframework" "$GHOSTTY_XCFRAMEWORK"
mkdir -p "$GHOSTTY_RESOURCES"
ditto "$GHOSTTY_INSTALL_PREFIX/share/ghostty" "$GHOSTTY_RESOURCES/ghostty"
ditto "$GHOSTTY_INSTALL_PREFIX/share/terminfo" "$GHOSTTY_RESOURCES/terminfo"

header="$GHOSTTY_XCFRAMEWORK/macos-arm64_x86_64/Headers/ghostty.h"
if [[ ! -f "$header" ]]; then
  header="$(find "$GHOSTTY_XCFRAMEWORK" -path '*/Headers/ghostty.h' -print -quit)"
fi
[[ -n "$header" && -f "$header" ]] || die "XCFramework does not contain ghostty.h"

library="$(find "$GHOSTTY_XCFRAMEWORK" -type f -name '*.a' -print -quit)"
[[ -n "$library" && -f "$library" ]] || die "XCFramework does not contain a static archive"

cat > "$GHOSTTY_ARTIFACT_ROOT/manifest.txt" <<EOF
ghostty_tag=$GHOSTTY_TAG
ghostty_commit=$GHOSTTY_COMMIT
ghostty_version=$GHOSTTY_VERSION
zig_version=$ZIG_VERSION
build_mode=ReleaseFast
sentry=false
xcframework_target=native
header_sha256=$(sha256_file "$header")
library_sha256=$(sha256_file "$library")
EOF

"$SCRIPT_DIR/verify.sh"
printf 'Ghostty artifact: %s\n' "$GHOSTTY_ARTIFACT_ROOT"
