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

cd "$REPO_ROOT"
exec caffeinate -dimsu xcodebuild \
  -project Coinor.xcodeproj \
  -scheme Coinor \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  "$@" \
  test
