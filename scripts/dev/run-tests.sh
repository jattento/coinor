#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIGURATION="Debug"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--configuration Debug|Release] [-- xcodebuild-arg ...]

Run the Coinor test suite unattended.

XCUITest cannot launch the built application while another process already
owns the dev.coinor.Coinor bundle identifier, and the unit-test host fails the
same way. This script terminates every running Coinor instance first, then runs
xcodebuild under caffeinate so display sleep cannot lock the session and abort
the user-interface tests.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "--configuration requires a value" >&2; exit 1; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

"$REPO_ROOT/scripts/dev/preflight.sh"

running_coinor_pids() {
  pgrep -f 'Coinor\.app/Contents/MacOS/Coinor' || true
}

pids="$(running_coinor_pids)"
if [[ -n "$pids" ]]; then
  echo "Quitting running Coinor instances: $(echo "$pids" | tr '\n' ' ')"
  osascript -e 'quit app "Coinor"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    [[ -z "$(running_coinor_pids)" ]] && break
    sleep 0.5
  done
  pids="$(running_coinor_pids)"
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill 2>/dev/null || true
    for _ in $(seq 1 20); do
      [[ -z "$(running_coinor_pids)" ]] && break
      sleep 0.5
    done
  fi
  pids="$(running_coinor_pids)"
  if [[ -n "$pids" ]]; then
    echo "Coinor is still running as $(echo "$pids" | tr '\n' ' '); the tests cannot launch the application." >&2
    exit 1
  fi
fi

TEST_SUPPORT_PARENT="${COINOR_TEST_SUPPORT_DIRECTORY:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_SUPPORT_PARENT"
TEST_SUPPORT_DIRECTORY="$(
  mktemp -d "${TEST_SUPPORT_PARENT%/}/CoinorTests.XXXXXX"
)"

ISOLATED_XCTESTRUN=""
cleanup() {
  exit_status=$?
  [[ -z "$ISOLATED_XCTESTRUN" ]] || rm -f "$ISOLATED_XCTESTRUN"
  if [[ "$exit_status" -eq 0 ]]; then
    rm -rf "$TEST_SUPPORT_DIRECTORY"
  else
    echo "Preserving failed test support directory: $TEST_SUPPORT_DIRECTORY" >&2
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"
caffeinate -dimsu xcodebuild \
  -project Coinor.xcodeproj \
  -scheme Coinor \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build-for-testing

XCTESTRUN="$(find .build/DerivedData/Build/Products \
  -maxdepth 1 \
  -type f \
  -name 'Coinor_*.xctestrun' \
  ! -name '*-isolated.xctestrun' \
  -exec stat -f '%m %N' {} \; \
  | sort -nr \
  | head -n 1 \
  | cut -d ' ' -f 2-)"
if [[ -z "$XCTESTRUN" ]]; then
  echo "build-for-testing did not produce a Coinor xctestrun file" >&2
  exit 1
fi

ISOLATED_XCTESTRUN="${XCTESTRUN%.xctestrun}-isolated.xctestrun"
echo "Selected xctestrun: $XCTESTRUN"
echo "Isolated support directory: $TEST_SUPPORT_DIRECTORY"
echo "Isolated xctestrun: $ISOLATED_XCTESTRUN"
cp "$XCTESTRUN" "$ISOLATED_XCTESTRUN"
XCTESTRUN_FORMAT="$(
  plutil -extract __xctestrun_metadata__.FormatVersion raw \
    "$ISOLATED_XCTESTRUN"
)"
if [[ "$XCTESTRUN_FORMAT" != "1" ]]; then
  echo "unsupported xctestrun format: $XCTESTRUN_FORMAT" >&2
  exit 1
fi
plutil -replace \
  CoinorTests.EnvironmentVariables.COINOR_APPLICATION_SUPPORT_DIRECTORY \
  -string "$TEST_SUPPORT_DIRECTORY" \
  "$ISOLATED_XCTESTRUN"
plutil -replace \
  CoinorUITests.EnvironmentVariables.COINOR_APPLICATION_SUPPORT_DIRECTORY \
  -string "$TEST_SUPPORT_DIRECTORY" \
  "$ISOLATED_XCTESTRUN"
plutil -replace \
  CoinorUITests.UITargetAppEnvironmentVariables.COINOR_APPLICATION_SUPPORT_DIRECTORY \
  -string "$TEST_SUPPORT_DIRECTORY" \
  "$ISOLATED_XCTESTRUN"
if [[ "${COINOR_RUN_LIVE_AGENTIC_FINDER:-}" == "1" ]]; then
  echo "Live installed-Grok Agent Search test: enabled"
  plutil -replace \
    CoinorTests.EnvironmentVariables.COINOR_RUN_LIVE_AGENTIC_FINDER \
    -string 1 \
    "$ISOLATED_XCTESTRUN"
else
  echo "Live installed-Grok Agent Search test: disabled"
fi

XCODEBUILD_ARGUMENTS=("$@")
UNIT_ARGUMENTS=("${XCODEBUILD_ARGUMENTS[@]}")
UI_ARGUMENTS=("${XCODEBUILD_ARGUMENTS[@]}")
for index in "${!XCODEBUILD_ARGUMENTS[@]}"; do
  if [[ "${XCODEBUILD_ARGUMENTS[$index]}" == "-resultBundlePath" ]] \
      && (( index + 1 < ${#XCODEBUILD_ARGUMENTS[@]} )); then
    result_path="${XCODEBUILD_ARGUMENTS[$((index + 1))]}"
    UNIT_ARGUMENTS[$((index + 1))]="${result_path%.xcresult}-unit.xcresult"
    UI_ARGUMENTS[$((index + 1))]="${result_path%.xcresult}-ui.xcresult"
  fi
done
if (( ${#UNIT_ARGUMENTS[@]} > 0 )); then
  echo "Unit xcodebuild arguments: ${UNIT_ARGUMENTS[*]}"
fi
if (( ${#UI_ARGUMENTS[@]} > 0 )); then
  echo "UI xcodebuild arguments: ${UI_ARGUMENTS[*]}"
fi

caffeinate -dimsu xcodebuild \
  test-without-building \
  -xctestrun "$ISOLATED_XCTESTRUN" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:CoinorTests \
  "${UNIT_ARGUMENTS[@]}"

caffeinate -dimsu xcodebuild \
  test-without-building \
  -xctestrun "$ISOLATED_XCTESTRUN" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:CoinorUITests \
  "${UI_ARGUMENTS[@]}"
