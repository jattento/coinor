#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_APP="$REPO_ROOT/.build/DerivedData/Build/Products/Release/Coinor.app"
APP_BUNDLE="${1:-$DEFAULT_APP}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || die "missing required file: $1"
}

require_directory() {
  [[ -d "$1" ]] || die "missing required directory: $1"
}

[[ "$#" -le 1 ]] || die "usage: $(basename "$0") [Coinor.app]"

require_directory "$APP_BUNDLE"

EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Coinor"
NOTICE="$APP_BUNDLE/Contents/Resources/ThirdPartyNotices.txt"
MANIFEST="$APP_BUNDLE/Contents/Resources/GhosttyArtifactManifest.txt"
SOURCE_MANIFEST="$REPO_ROOT/Vendor/Ghostty/manifest.txt"
GHOSTTY_RESOURCES="$APP_BUNDLE/Contents/Resources/ghostty"
TERMINFO="$APP_BUNDLE/Contents/Resources/terminfo"

require_file "$EXECUTABLE"
require_file "$NOTICE"
require_file "$MANIFEST"
require_file "$SOURCE_MANIFEST"
require_directory "$GHOSTTY_RESOURCES"
require_directory "$TERMINFO"

[[ -x "$EXECUTABLE" ]] || die "Coinor executable is not runnable"

"$REPO_ROOT/scripts/ghostty/verify.sh" \
  --artifact-root "$REPO_ROOT/Vendor/Ghostty" >/dev/null

cmp -s "$SOURCE_MANIFEST" "$MANIFEST" || \
  die "bundled Ghostty manifest does not match Vendor/Ghostty"

grep -Fq 'Source tag: v1.3.1' "$NOTICE" || \
  die "Ghostty source tag is missing from ThirdPartyNotices.txt"
grep -Fq 'Source commit: 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28' \
  "$NOTICE" || die "Ghostty source commit is missing from ThirdPartyNotices.txt"
grep -Fq 'MIT License' "$NOTICE" || \
  die "Ghostty MIT license is missing from ThirdPartyNotices.txt"

codesign --verify --deep --strict "$APP_BUNDLE"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
require_file "$INFO_PLIST"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")"
short_version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
build_version="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"

[[ "$bundle_id" == "dev.coinor.Coinor" ]] || \
  die "unexpected bundle identifier: $bundle_id"
[[ "$minimum_system" == "13.0" ]] || \
  die "unexpected minimum macOS version: $minimum_system"
[[ -n "$short_version" && -n "$build_version" ]] || \
  die "bundle version metadata is incomplete"

app_architectures="$(lipo -archs "$EXECUTABLE")"
[[ "$app_architectures" == "arm64" ]] || \
  die "Coinor must be arm64-only, got: $app_architectures"

if otool -L "$EXECUTABLE" | grep -Fq '/Applications/Ghostty.app'; then
  die "Coinor unexpectedly depends on /Applications/Ghostty.app"
fi

entitlements="$(mktemp)"
trap 'rm -f "$entitlements"' EXIT HUP INT TERM
codesign -d --entitlements :- "$APP_BUNDLE" >"$entitlements" 2>/dev/null
if /usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
  die "Release bundle unexpectedly enables get-task-allow"
fi

app_sandbox="$(
  /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null || true
)"
[[ "$app_sandbox" == "false" ]] || \
  die "Release bundle must explicitly disable App Sandbox"

printf 'verified_app=%s\n' "$APP_BUNDLE"
printf 'verified_bundle_id=%s\n' "$bundle_id"
printf 'verified_version=%s (%s)\n' "$short_version" "$build_version"
printf 'verified_minimum_macos=%s\n' "$minimum_system"
printf 'verified_architecture=%s\n' "$app_architectures"
printf 'verified_ghostty_commit=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28\n'
printf 'verified_codesign=deep-strict\n'
printf 'verified_app_sandbox=false\n'
printf 'verified_get_task_allow=false\n'
