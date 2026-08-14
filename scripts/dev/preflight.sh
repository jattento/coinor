#!/bin/bash

set -euo pipefail

export LANG=C
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
EXPECTED_XCODE_VERSION="26.6"
EXPECTED_XCODE_BUILD="17F113"
EXPECTED_MACOS_SDK="26.5"

fail() {
  printf 'Coinor unattended preflight failed: %s\n' "$1" >&2
  if [[ $# -ge 2 ]]; then
    printf 'Remediation: %s\n' "$2" >&2
  fi
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || \
    fail "required command is unavailable: $1" "$2"
}

require_command xcode-select \
  "Install the validated Xcode release, then select it with sudo xcode-select -s /Applications/Xcode.app."
require_command xcodebuild \
  "Install Xcode ${EXPECTED_XCODE_VERSION} (${EXPECTED_XCODE_BUILD})."
require_command xcrun \
  "Install Xcode ${EXPECTED_XCODE_VERSION} (${EXPECTED_XCODE_BUILD}) and its command-line tools."
require_command sw_vers "Run this preflight on macOS."
require_command DevToolsSecurity \
  "Run sudo DevToolsSecurity -enable before unattended XCTest/XCUITest work."
require_command security \
  "Run this preflight on macOS with the system security tool available."
require_command plutil "Run this preflight on macOS."
require_command caffeinate "Run this preflight on macOS."

architecture="$(uname -m)"
[[ "$architecture" == "arm64" ]] || \
  fail "unsupported host architecture: $architecture" \
    "Use the validated Apple Silicon build host."

macos_version="$(sw_vers -productVersion)"

active_developer_dir="$(xcode-select -p 2>/dev/null || true)"
[[ "$active_developer_dir" == "$EXPECTED_DEVELOPER_DIR" ]] || \
  fail \
    "active developer directory is ${active_developer_dir:-unavailable}; expected $EXPECTED_DEVELOPER_DIR" \
    "Run sudo xcode-select -s /Applications/Xcode.app and rerun scripts/dev/preflight.sh."
[[ -x "$active_developer_dir/usr/bin/xcodebuild" ]] || \
  fail "the selected Xcode installation is incomplete" \
    "Reinstall Xcode ${EXPECTED_XCODE_VERSION} (${EXPECTED_XCODE_BUILD})."

temp_directory="${TMPDIR:-/tmp}"
[[ -d "$temp_directory" && -w "$temp_directory" ]] || \
  fail "the temporary directory is not writable: $temp_directory" \
    "Fix TMPDIR permissions or select a writable temporary directory before unattended work."
temp_probe="$(mktemp "$temp_directory/coinor-preflight.XXXXXX")" || \
  fail "cannot create a temporary preflight file in $temp_directory" \
    "Fix TMPDIR permissions or free disk space before unattended work."
rm -f "$temp_probe"

license_error=""
if ! license_error="$(xcodebuild -license check 2>&1 >/dev/null)"; then
  detail="$(printf '%s' "$license_error" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  fail \
    "the Xcode license is not accepted${detail:+: $detail}" \
    "Before leaving the machine unattended, run sudo xcodebuild -license accept and rerun scripts/dev/preflight.sh."
fi

first_launch_error=""
if ! first_launch_error="$(xcodebuild -checkFirstLaunchStatus 2>&1 >/dev/null)"; then
  detail="$(printf '%s' "$first_launch_error" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  fail \
    "Xcode first-launch components are incomplete${detail:+: $detail}" \
    "Before leaving the machine unattended, run sudo xcodebuild -runFirstLaunch and rerun scripts/dev/preflight.sh."
fi

xcode_version_output="$(xcodebuild -version 2>&1)" || \
  fail "xcodebuild cannot report its version: $xcode_version_output" \
    "Repair or reinstall the validated Xcode release."
xcode_version="$(printf '%s\n' "$xcode_version_output" | awk '/^Xcode / { print $2; exit }')"
xcode_build="$(printf '%s\n' "$xcode_version_output" | awk '/^Build version / { print $3; exit }')"
[[ "$xcode_version" == "$EXPECTED_XCODE_VERSION" \
  && "$xcode_build" == "$EXPECTED_XCODE_BUILD" ]] || \
  fail \
    "Xcode $xcode_version ($xcode_build) is active; expected $EXPECTED_XCODE_VERSION ($EXPECTED_XCODE_BUILD)" \
    "Select the validated Xcode release, or validate the new toolchain interactively and update the pins in scripts/dev/preflight.sh."

sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || \
  fail "the selected Xcode cannot resolve the macOS SDK" \
    "Complete Xcode first launch or reinstall the validated Xcode release."
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || \
  fail "the selected Xcode cannot report the macOS SDK version" \
    "Complete Xcode first launch or reinstall the validated Xcode release."
[[ "$sdk_version" == "$EXPECTED_MACOS_SDK" ]] || \
  fail \
    "macOS SDK $sdk_version is active; expected $EXPECTED_MACOS_SDK" \
    "Select Xcode ${EXPECTED_XCODE_VERSION} (${EXPECTED_XCODE_BUILD}), or validate and pin the new SDK deliberately."
[[ -d "$sdk_path" ]] || \
  fail "reported macOS SDK path does not exist: $sdk_path" \
    "Repair or reinstall the selected Xcode release."

swift_version_output="$(xcrun --sdk macosx swiftc -version 2>&1)" || \
  fail "Swift compiler is unavailable: $swift_version_output" \
    "Repair or reinstall the selected Xcode release."
swift_version="$(
  printf '%s\n' "$swift_version_output" \
    | grep -o 'Apple Swift version 6\.[^[:cntrl:]]*' \
    | head -n 1 \
    || true
)"
[[ -n "$swift_version" ]] || \
  fail "Swift 6 is required; got: $(printf '%s' "$swift_version_output" | head -n 1)" \
    "Select the validated Xcode release."

DevToolsSecurity -status 2>&1 | grep -Fq 'Developer mode is currently enabled.' || \
  fail "Developer Tools access is disabled" \
    "Before leaving the machine unattended, run sudo DevToolsSecurity -enable and rerun scripts/dev/preflight.sh."

taskport_payload="$(
  security authorizationdb read system.privilege.taskport 2>/dev/null
)" || fail "cannot read system.privilege.taskport authorization" \
  "Verify macOS authorization services, then rerun scripts/dev/preflight.sh."
taskport_rule="$(
  printf '%s' "$taskport_payload" \
    | plutil -extract rule.0 raw -o - - 2>/dev/null \
    || true
)"
[[ "$taskport_rule" == "allow" ]] || \
  fail \
    "system.privilege.taskport is not pre-authorized for unattended UI tests" \
    "Before leaving the machine unattended, run sudo security authorizationdb write system.privilege.taskport allow and rerun scripts/dev/preflight.sh."

# XCUITest asks testmanagerd to enter automation mode, which is authorized by
# com.apple.dt.AutomationModeUI. macOS ships no rule for that right, so it falls
# back to authenticating an administrator and raises a Touch ID / password
# dialog on EVERY run — an unattended session cannot answer it, and an attended
# one is asked again the next time. Granting the right once is what makes the
# dialog stop.
automation_payload="$(
  security authorizationdb read com.apple.dt.AutomationModeUI 2>/dev/null
)" || fail \
  "com.apple.dt.AutomationModeUI has no authorization rule, so XCUITest will raise a Touch ID prompt it cannot answer" \
  "Run sudo security authorizationdb write com.apple.dt.AutomationModeUI allow once, then rerun scripts/dev/preflight.sh."
automation_rule="$(
  printf '%s' "$automation_payload" \
    | plutil -extract rule.0 raw -o - - 2>/dev/null \
    || true
)"
[[ "$automation_rule" == "allow" ]] || \
  fail \
    "com.apple.dt.AutomationModeUI is not pre-authorized for unattended UI tests" \
    "Run sudo security authorizationdb write com.apple.dt.AutomationModeUI allow once, then rerun scripts/dev/preflight.sh."

[[ -f "$REPO_ROOT/Coinor.xcodeproj/project.pbxproj" ]] || \
  fail "Coinor.xcodeproj is missing" "Run the preflight from a complete Coinor checkout."

destinations="$(
  cd "$REPO_ROOT"
  xcodebuild \
    -project Coinor.xcodeproj \
    -scheme Coinor \
    -showdestinations 2>&1
)" || fail "Xcode cannot load the Coinor scheme: $destinations" \
  "Open the project interactively and repair the selected toolchain or scheme before unattended work."
printf '%s\n' "$destinations" | grep -Eq 'platform:macOS, arch:arm64' || \
  fail "the Coinor scheme has no arm64 macOS destination" \
    "Open Xcode and repair the local platform installation before unattended work."

build_directory="$REPO_ROOT/.build"
if [[ -d "$build_directory" ]]; then
  build_probe_parent="$build_directory"
else
  build_probe_parent="$REPO_ROOT"
fi
[[ -w "$build_probe_parent" ]] || \
  fail "the build parent is not writable: $build_probe_parent" \
    "Fix ownership or free disk space before unattended work."
build_probe="$(mktemp "$build_probe_parent/.coinor-preflight.XXXXXX")" || \
  fail "cannot create a build writability probe in $build_probe_parent" \
    "Fix ownership or free disk space before unattended work."
rm -f "$build_probe"

printf 'Coinor unattended preflight passed.\n'
printf 'host_macos=%s\n' "$macos_version"
printf 'host_architecture=%s\n' "$architecture"
printf 'developer_dir=%s\n' "$active_developer_dir"
printf 'xcode=%s (%s)\n' "$xcode_version" "$xcode_build"
printf 'macos_sdk=%s\n' "$sdk_version"
printf 'swift=%s\n' "$swift_version"
printf 'developer_tools_security=enabled\n'
printf 'taskport_authorization=allow\n'
printf 'automation_mode_authorization=allow\n'
printf 'destination=platform:macOS,arch:arm64\n'
