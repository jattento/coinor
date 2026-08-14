#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/dev/preflight.sh"
RUN_TESTS="$REPO_ROOT/scripts/dev/run-tests.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/coinor-preflight-tests.XXXXXX")"
SHIMS="$SCRATCH/shims"
TEST_TMP="$SCRATCH/tmp"
MARKER="$SCRATCH/side-effect-marker"

cleanup() {
  rm -rf "$SCRATCH"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$SHIMS" "$TEST_TMP"

real_path() {
  command -v "$1"
}

REAL_XCODE_SELECT="$(real_path xcode-select)"
REAL_XCODEBUILD="$(real_path xcodebuild)"
REAL_XCRUN="$(real_path xcrun)"
REAL_SW_VERS="$(real_path sw_vers)"
REAL_DEVTOOLS_SECURITY="$(real_path DevToolsSecurity)"
REAL_SECURITY="$(real_path security)"
REAL_UNAME="$(real_path uname)"
REAL_PGREP="$(real_path pgrep)"

cat > "$SHIMS/xcode-select" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "developer-dir" ]]; then
  echo /Library/Developer/CommandLineTools
  exit 0
fi
exec "$REAL_XCODE_SELECT" "\$@"
EOF

cat > "$SHIMS/sw_vers" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "macos" && "\${1:-}" == "-productVersion" ]]; then
  echo 99.0
  exit 0
fi
exec "$REAL_SW_VERS" "\$@"
EOF

cat > "$SHIMS/uname" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "architecture" && "\${1:-}" == "-m" ]]; then
  echo x86_64
  exit 0
fi
exec "$REAL_UNAME" "\$@"
EOF

cat > "$SHIMS/xcodebuild" <<EOF
#!/bin/bash
case "\${COINOR_PREFLIGHT_TEST_CASE:-}:\${1:-}:\${2:-}" in
  license:-license:check)
    echo 'Xcode license agreements have not been accepted.' >&2
    exit 69
    ;;
  first-launch:-checkFirstLaunchStatus:)
    echo 'Additional Xcode components are required.' >&2
    exit 1
    ;;
  xcode-version:-version:)
    printf 'Xcode 99.0\nBuild version 99A1\n'
    exit 0
    ;;
esac
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "destination" && " \$* " == *" -showdestinations "* ]]; then
  printf 'Available destinations for the "Coinor" scheme:\n{ platform:macOS, name:Any Mac }\n'
  exit 0
fi
exec "$REAL_XCODEBUILD" "\$@"
EOF

cat > "$SHIMS/xcrun" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "sdk" && " \$* " == *" --show-sdk-version "* ]]; then
  echo 99.0
  exit 0
fi
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "swift" && " \$* " == *" swiftc -version "* ]]; then
  echo 'Apple Swift version 5.10'
  exit 0
fi
exec "$REAL_XCRUN" "\$@"
EOF

cat > "$SHIMS/DevToolsSecurity" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "developer-tools" ]]; then
  echo 'Developer mode is currently disabled.'
  exit 0
fi
exec "$REAL_DEVTOOLS_SECURITY" "\$@"
EOF

cat > "$SHIMS/security" <<EOF
#!/bin/bash
if [[ "\${COINOR_PREFLIGHT_TEST_CASE:-}" == "taskport" ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>rule</key><array><string>authenticate-admin</string></array></dict></plist>
PLIST
  exit 0
fi
exec "$REAL_SECURITY" "\$@"
EOF

cat > "$SHIMS/pgrep" <<EOF
#!/bin/bash
printf 'pgrep reached\n' > "$MARKER"
exec "$REAL_PGREP" "\$@"
EOF

chmod +x "$SHIMS"/*

expect_failure() {
  local test_case="$1"
  local expected="$2"
  local output="$SCRATCH/$test_case.out"
  if COINOR_PREFLIGHT_TEST_CASE="$test_case" \
      PATH="$SHIMS:$PATH" \
      TMPDIR="$TEST_TMP" \
      "$PREFLIGHT" >"$output" 2>&1; then
    echo "expected preflight case '$test_case' to fail" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    echo "preflight case '$test_case' missed expected diagnostic: $expected" >&2
    cat "$output" >&2
    exit 1
  }
}

expect_failure architecture "unsupported host architecture: x86_64"
expect_failure macos "macOS 99.0 is not the validated 26.5 series"
expect_failure developer-dir "active developer directory is /Library/Developer/CommandLineTools"
expect_failure license "the Xcode license is not accepted"
expect_failure first-launch "Xcode first-launch components are incomplete"
expect_failure xcode-version "Xcode 99.0 (99A1) is active"
expect_failure sdk "macOS SDK 99.0 is active"
expect_failure swift "Swift 6 is required"
expect_failure developer-tools "Developer Tools access is disabled"
expect_failure taskport "system.privilege.taskport is not pre-authorized"
expect_failure destination "the Coinor scheme has no arm64 macOS destination"

bad_tmp="$SCRATCH/not-a-directory"
printf 'occupied' > "$bad_tmp"
if PATH="$SHIMS:$PATH" TMPDIR="$bad_tmp" "$PREFLIGHT" \
    >"$SCRATCH/temp.out" 2>&1; then
  echo "expected unwritable TMPDIR preflight to fail" >&2
  exit 1
fi
grep -Fq "the temporary directory is not writable: $bad_tmp" \
  "$SCRATCH/temp.out"

rm -f "$MARKER"
if COINOR_PREFLIGHT_TEST_CASE=macos \
    PATH="$SHIMS:$PATH" \
    TMPDIR="$TEST_TMP" \
    "$RUN_TESTS" >"$SCRATCH/run-tests.out" 2>&1; then
  echo "expected run-tests to stop at preflight" >&2
  exit 1
fi
grep -Fq "macOS 99.0 is not the validated 26.5 series" \
  "$SCRATCH/run-tests.out"
[[ ! -e "$MARKER" ]] || {
  echo "run-tests reached Coinor process handling before preflight passed" >&2
  exit 1
}

before_probes="$(
  find "$REPO_ROOT" "$REPO_ROOT/.build" \
    -maxdepth 1 -name '.coinor-preflight.*' -print 2>/dev/null \
    | sort
)"
TMPDIR="$TEST_TMP" "$PREFLIGHT" >"$SCRATCH/happy.out"
after_probes="$(
  find "$REPO_ROOT" "$REPO_ROOT/.build" \
    -maxdepth 1 -name '.coinor-preflight.*' -print 2>/dev/null \
    | sort
)"
[[ "$before_probes" == "$after_probes" ]] || {
  echo "preflight left a repository probe artifact" >&2
  diff -u <(printf '%s\n' "$before_probes") <(printf '%s\n' "$after_probes") >&2 || true
  exit 1
}
grep -Fq "Coinor unattended preflight passed." "$SCRATCH/happy.out"

printf 'Coinor unattended preflight tests passed.\n'
