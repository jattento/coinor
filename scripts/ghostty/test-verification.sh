#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command cp
require_command ditto
require_command mktemp

source_root="$GHOSTTY_ARTIFACT_ROOT"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/coinor-ghostty-verification.XXXXXX")"
baseline="$test_root/baseline"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

copy_fixture() {
  local source="$1"
  local destination="$2"

  rm -rf "$destination"
  if ! cp -cR "$source" "$destination" 2>/dev/null; then
    rm -rf "$destination"
    ditto "$source" "$destination"
  fi
}

expect_verification_failure() {
  local name="$1"
  local artifact="$2"
  local expected_message="$3"
  local output

  if output="$("$SCRIPT_DIR/verify.sh" --artifact-root "$artifact" 2>&1)"; then
    printf 'error: %s corruption unexpectedly passed verification\n' "$name" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected_message"* ]]; then
    printf 'error: %s corruption failed without the expected diagnostic\n' "$name" >&2
    printf 'expected: %s\n' "$expected_message" >&2
    printf 'actual: %s\n' "$output" >&2
    exit 1
  fi

  printf 'verified_failure=%s\n' "$name"
}

"$SCRIPT_DIR/install-app-artifact.sh" \
  --source-root "$source_root" \
  --destination-root "$baseline" >/dev/null
"$SCRIPT_DIR/verify.sh" --artifact-root "$baseline" >/dev/null
printf 'verified_happy_path=true\n'

header_case="$test_root/header"
copy_fixture "$baseline" "$header_case"
header="$(find "$header_case/GhosttyKit.xcframework" -path '*/Headers/ghostty.h' -type f -print -quit)"
printf '\n/* verification corruption */\n' >> "$header"
expect_verification_failure \
  header \
  "$header_case" \
  "Ghostty public header checksum mismatch"

framework_case="$test_root/framework"
copy_fixture "$baseline" "$framework_case"
printf '\n// verification corruption\n' >> \
  "$framework_case/GhosttyKit.xcframework/macos-arm64/Headers/module.modulemap"
expect_verification_failure \
  framework \
  "$framework_case" \
  "Ghostty XCFramework checksum mismatch"

resources_case="$test_root/resources"
copy_fixture "$baseline" "$resources_case"
printf '\n# verification corruption\n' >> \
  "$resources_case/Resources/ghostty/themes/0x96f"
expect_verification_failure \
  resources \
  "$resources_case" \
  "Ghostty resources checksum mismatch"

manifest_case="$test_root/manifest"
copy_fixture "$baseline" "$manifest_case"
manifest_tmp="$manifest_case/manifest.txt.tmp"
awk -F= '
  $1 == "ghostty_commit" {
    print "ghostty_commit=0000000000000000000000000000000000000000"
    next
  }
  { print }
' "$manifest_case/manifest.txt" > "$manifest_tmp"
mv "$manifest_tmp" "$manifest_case/manifest.txt"
expect_verification_failure \
  manifest \
  "$manifest_case" \
  "artifact manifest ghostty_commit mismatch"

printf 'Ghostty artifact verification tests passed.\n'
