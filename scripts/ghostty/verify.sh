#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command file
require_command git
require_command nm
require_command plutil

[[ -d "$GHOSTTY_XCFRAMEWORK" ]] || die "missing XCFramework: $GHOSTTY_XCFRAMEWORK"
[[ -f "$GHOSTTY_XCFRAMEWORK/Info.plist" ]] || die "missing XCFramework Info.plist"
[[ -f "$GHOSTTY_ARTIFACT_ROOT/manifest.txt" ]] || die "missing artifact manifest"
[[ -f "$GHOSTTY_RESOURCES/terminfo/78/xterm-ghostty" ]] || \
  die "missing compiled xterm-ghostty terminfo"
[[ -d "$GHOSTTY_RESOURCES/ghostty/shell-integration" ]] || \
  die "missing Ghostty shell integration resources"
[[ -d "$GHOSTTY_RESOURCES/ghostty/themes" ]] || \
  die "missing Ghostty themes"

actual_commit="$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)"
[[ "$actual_commit" == "$GHOSTTY_COMMIT" ]] || \
  die "source revision mismatch: expected $GHOSTTY_COMMIT, got $actual_commit"

manifest_commit="$(awk -F= '$1 == "ghostty_commit" {print $2}' "$GHOSTTY_ARTIFACT_ROOT/manifest.txt")"
[[ "$manifest_commit" == "$GHOSTTY_COMMIT" ]] || \
  die "artifact manifest revision mismatch"

library="$(find "$GHOSTTY_XCFRAMEWORK" -type f -name '*.a' -print -quit)"
[[ -n "$library" ]] || die "missing static Ghostty library"
file "$library" | grep -q 'current ar archive' || die "Ghostty library is not a static archive"

if nm -gU "$library" 2>/dev/null | grep -qi sentry; then
  die "Ghostty static library unexpectedly exports Sentry symbols"
fi

plutil -lint "$GHOSTTY_XCFRAMEWORK/Info.plist" >/dev/null

printf 'verified_tag=%s\n' "$GHOSTTY_TAG"
printf 'verified_commit=%s\n' "$actual_commit"
printf 'verified_library=%s\n' "$library"
printf 'verified_resources=%s\n' "$GHOSTTY_RESOURCES"
printf 'verified_sentry=false\n'
