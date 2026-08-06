#!/bin/bash

set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$SPIKE_ROOT/.build/app/CoinorGhosttySpike.app"
EXECUTABLE="$APP/Contents/MacOS/GhosttySpike"
EVENT_LOG="$SPIKE_ROOT/.build/minimal-environment-events.log"
PROCESS_LOG="$SPIKE_ROOT/.build/minimal-environment-process.log"
SANDBOX_PROFILE="$SPIKE_ROOT/.build/deny-installed-ghostty.sb"
DENIED_PROBE_LOG="$SPIKE_ROOT/.build/deny-installed-ghostty-probe.log"
RESOURCES="$APP/Contents/Resources/ghostty"

"$SPIKE_ROOT/build.sh"

cat > "$SANDBOX_PROFILE" <<EOF
(version 1)
(allow default)
(deny file-read* (subpath "/Applications/Ghostty.app"))
EOF

env -i \
  HOME="$HOME" \
  USER="$(id -un)" \
  LOGNAME="$(id -un)" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  TMPDIR="${TMPDIR:-/tmp}" \
  "$EXECUTABLE" \
  --event-log "$EVENT_LOG" \
  --cwd "$SPIKE_ROOT" \
  --exit-after 2.5 \
  >"$PROCESS_LOG" 2>&1

env -i \
  HOME="$HOME" \
  USER="$(id -un)" \
  LOGNAME="$(id -un)" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  TMPDIR="${TMPDIR:-/tmp}" \
  /usr/bin/sandbox-exec -f "$SANDBOX_PROFILE" \
  "$EXECUTABLE" \
  --config-probe \
  --resources "$RESOURCES" \
  >"$DENIED_PROBE_LOG" 2>&1

grep -q 'app_started' "$EVENT_LOG"
grep -q 'command_started' "$EVENT_LOG"
grep -q 'finder_environment_path=/usr/bin:/bin:/usr/sbin:/sbin' "$EVENT_LOG"
grep -q 'surface_destroyed' "$EVENT_LOG"
grep -q 'runtime_destroyed' "$EVENT_LOG"
grep -q 'app_terminated' "$EVENT_LOG"
grep -q '"fontSize"' "$DENIED_PROBE_LOG"
if grep -q 'startup_failed' "$EVENT_LOG"; then
  printf 'minimal environment launch reported startup failure\n' >&2
  exit 1
fi

if otool -L "$EXECUTABLE" | grep -q '/Applications/Ghostty.app'; then
  printf 'unexpected dynamic dependency on installed Ghostty.app\n' >&2
  exit 1
fi
if strings "$EXECUTABLE" | grep -q '/Applications/Ghostty.app'; then
  printf 'unexpected embedded reference to installed Ghostty.app\n' >&2
  exit 1
fi

entitlements="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
if grep -q 'com.apple.security.app-sandbox' <<<"$entitlements"; then
  printf 'spike unexpectedly enables App Sandbox\n' >&2
  exit 1
fi

while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    printf 'minimal-environment terminal child still alive: %s\n' "$pid" >&2
    exit 1
  fi
done < <(awk -F'[ =]' '/command_started/ {for (i=1; i<=NF; i++) if ($i == "pid") print $(i+1)}' "$EVENT_LOG")

printf 'minimal_environment_launch=passed\n'
printf 'installed_ghostty_read_denied_for_config_and_resources=passed\n'
printf 'app_sandbox=disabled\n'
printf 'absolute_command=passed\n'
