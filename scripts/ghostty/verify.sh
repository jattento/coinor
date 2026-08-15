#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

artifact_root="$GHOSTTY_ARTIFACT_ROOT"
artifact_root_was_explicit=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--artifact-root PATH]

Verify a Ghostty artifact. The default is the Phase 0 build artifact:
  $GHOSTTY_ARTIFACT_ROOT

Use --artifact-root to verify the installed artifact consumed by Xcode:
  $GHOSTTY_APP_ARTIFACT_ROOT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-root)
      [[ $# -ge 2 ]] || die "--artifact-root requires a path"
      artifact_root="$2"
      artifact_root_was_explicit=true
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ "$artifact_root_was_explicit" == true ]]; then
        die "artifact root was provided more than once"
      fi
      artifact_root="$1"
      artifact_root_was_explicit=true
      shift
      ;;
  esac
done

require_command file
require_command nm
require_command plutil
require_command readlink
require_command shasum
require_command sort

xcframework="$artifact_root/GhosttyKit.xcframework"
resources="$artifact_root/Resources"
manifest="$artifact_root/manifest.txt"

[[ -d "$artifact_root" ]] || die "missing Ghostty artifact directory: $artifact_root"
[[ -d "$xcframework" ]] || die "missing XCFramework: $xcframework"
[[ -f "$xcframework/Info.plist" ]] || die "missing XCFramework Info.plist: $xcframework/Info.plist"
[[ -f "$manifest" ]] || die "missing artifact manifest: $manifest"
[[ -f "$resources/terminfo/78/xterm-ghostty" ]] || \
  die "missing compiled xterm-ghostty terminfo"
[[ -d "$resources/ghostty/shell-integration" ]] || \
  die "missing Ghostty shell integration resources"
[[ -d "$resources/ghostty/themes" ]] || \
  die "missing Ghostty themes"

malformed_line="$(
  awk 'NF > 0 && $0 !~ /^[A-Za-z0-9_]+=/ { print NR; exit }' "$manifest"
)"
[[ -z "$malformed_line" ]] || \
  die "artifact manifest contains a malformed entry at line $malformed_line"

manifest_value() {
  local key="$1"
  local count

  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$manifest")"
  [[ "$count" -eq 1 ]] || \
    die "artifact manifest must contain exactly one $key entry; found $count"

  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' "$manifest"
}

expect_manifest_value() {
  local key="$1"
  local expected="$2"
  local actual

  actual="$(manifest_value "$key")"
  [[ "$actual" == "$expected" ]] || \
    die "artifact manifest $key mismatch: expected $expected, got $actual"
}

expect_manifest_value ghostty_tag "$GHOSTTY_TAG"
expect_manifest_value ghostty_commit "$GHOSTTY_COMMIT"
expect_manifest_value ghostty_version "$GHOSTTY_VERSION"
expect_manifest_value zig_version "$ZIG_VERSION"
expect_manifest_value build_mode ReleaseFast
expect_manifest_value sentry false
expect_manifest_value xcframework_target native

header="$(find "$xcframework" -path '*/Headers/ghostty.h' -type f -print -quit)"
[[ -n "$header" ]] || die "missing Ghostty public header in XCFramework"

library="$(find "$xcframework" -type f -name '*.a' -print -quit)"
[[ -n "$library" ]] || die "missing static Ghostty library"

expected_header_sha="$(manifest_value header_sha256)"
[[ "$expected_header_sha" =~ ^[0-9a-f]{64}$ ]] || \
  die "artifact manifest header_sha256 is not a lowercase SHA-256 digest"
actual_header_sha="$(sha256_file "$header")"
[[ "$actual_header_sha" == "$expected_header_sha" ]] || \
  die "Ghostty public header checksum mismatch: expected $expected_header_sha, got $actual_header_sha"

expected_library_sha="$(manifest_value library_sha256)"
[[ "$expected_library_sha" =~ ^[0-9a-f]{64}$ ]] || \
  die "artifact manifest library_sha256 is not a lowercase SHA-256 digest"
actual_library_sha="$(sha256_file "$library")"
[[ "$actual_library_sha" == "$expected_library_sha" ]] || \
  die "Ghostty static library checksum mismatch: expected $expected_library_sha, got $actual_library_sha"

xcframework_digest_count="$(
  awk -F= '$1 == "xcframework_sha256" { count++ } END { print count + 0 }' "$manifest"
)"
if [[ "$xcframework_digest_count" -eq 0 ]]; then
  expected_xcframework_sha="$GHOSTTY_XCFRAMEWORK_SHA256"
  printf 'warning: legacy artifact manifest has no xcframework_sha256; validating against the pinned compatibility digest\n' \
    >&2
else
  [[ "$xcframework_digest_count" -eq 1 ]] || \
    die "artifact manifest must contain exactly one xcframework_sha256 entry; found $xcframework_digest_count"
  expected_xcframework_sha="$(manifest_value xcframework_sha256)"
  [[ "$expected_xcframework_sha" =~ ^[0-9a-f]{64}$ ]] || \
    die "artifact manifest xcframework_sha256 is not a lowercase SHA-256 digest"
fi
actual_xcframework_sha="$(sha256_tree "$xcframework")"
[[ "$actual_xcframework_sha" == "$expected_xcframework_sha" ]] || \
  die "Ghostty XCFramework checksum mismatch: expected $expected_xcframework_sha, got $actual_xcframework_sha"

resources_digest_count="$(
  awk -F= '$1 == "resources_sha256" { count++ } END { print count + 0 }' "$manifest"
)"
if [[ "$resources_digest_count" -eq 0 ]]; then
  expected_resources_sha="$GHOSTTY_RESOURCES_SHA256"
  printf 'warning: legacy artifact manifest has no resources_sha256; validating against the pinned compatibility digest\n' \
    >&2
else
  [[ "$resources_digest_count" -eq 1 ]] || \
    die "artifact manifest must contain exactly one resources_sha256 entry; found $resources_digest_count"
  expected_resources_sha="$(manifest_value resources_sha256)"
  [[ "$expected_resources_sha" =~ ^[0-9a-f]{64}$ ]] || \
    die "artifact manifest resources_sha256 is not a lowercase SHA-256 digest"
fi
actual_resources_sha="$(sha256_tree "$resources")"
[[ "$actual_resources_sha" == "$expected_resources_sha" ]] || \
  die "Ghostty resources checksum mismatch: expected $expected_resources_sha, got $actual_resources_sha"

file "$library" | grep -q 'current ar archive' || die "Ghostty library is not a static archive"

# Checksums only prove the archive is the one this build produced, not that it
# is usable: an archiver that drops members yields a well-formed archive that
# exports nothing and fails at app link time. Assert the entry points the app
# actually calls.
library_symbols="$(nm -gU "$library" 2>/dev/null)"
for required_symbol in \
  _ghostty_app_new \
  _ghostty_app_free \
  _ghostty_app_tick \
  _ghostty_app_set_focus \
  _ghostty_app_update_config
do
  grep -q " T $required_symbol\$" <<<"$library_symbols" || \
    die "Ghostty static library does not export $required_symbol; the archiver dropped members"
done

if grep -qi sentry <<<"$library_symbols"; then
  die "Ghostty static library unexpectedly exports Sentry symbols"
fi

plutil -lint "$xcframework/Info.plist" >/dev/null

printf 'verified_tag=%s\n' "$GHOSTTY_TAG"
printf 'verified_commit=%s\n' "$GHOSTTY_COMMIT"
printf 'verified_artifact_root=%s\n' "$artifact_root"
printf 'verified_header_sha256=%s\n' "$actual_header_sha"
printf 'verified_library_sha256=%s\n' "$actual_library_sha"
printf 'verified_xcframework_sha256=%s\n' "$actual_xcframework_sha"
printf 'verified_resources_sha256=%s\n' "$actual_resources_sha"
printf 'verified_library=%s\n' "$library"
printf 'verified_resources=%s\n' "$resources"
printf 'verified_sentry=false\n'
