#!/bin/bash

set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$SPIKE_ROOT/.build/app/CoinorGhosttySpike.app"
EXECUTABLE="$APP/Contents/MacOS/GhosttySpike"
RESOURCES="$APP/Contents/Resources/ghostty"
FIXTURE="$SPIKE_ROOT/.build/config-fixture"

"$SPIKE_ROOT/build.sh"

rm -rf "$FIXTURE"
mkdir -p "$FIXTURE/home" "$FIXTURE/xdg/ghostty"
cat > "$FIXTURE/xdg/ghostty/config" <<EOF
font-size = 17
config-file = child.conf
EOF
cat > "$FIXTURE/xdg/ghostty/child.conf" <<EOF
font-size = 23
background = 112233
EOF

probe_output="$(
  env -i \
    HOME="$FIXTURE/home" \
    XDG_CONFIG_HOME="$FIXTURE/xdg" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    "$EXECUTABLE" --config-probe --resources "$RESOURCES"
)"

printf '%s\n' "$probe_output"
font_size="$(jq -r .fontSize <<<"$probe_output")"
background="$(jq -r .background <<<"$probe_output")"
diagnostics="$(jq -r '.diagnostics | length' <<<"$probe_output")"
[[ "$font_size" == "23" ]]
[[ "$background" == "112233" ]]
[[ "$diagnostics" == "0" ]]

if otool -L "$EXECUTABLE" | grep -q '/Applications/Ghostty.app'; then
  printf 'unexpected runtime dependency on Ghostty.app\n' >&2
  exit 1
fi
if strings "$EXECUTABLE" | grep -q '/Applications/Ghostty.app'; then
  printf 'unexpected embedded path to Ghostty.app\n' >&2
  exit 1
fi

printf 'config_recursive_load=passed\n'
printf 'ghostty_app_dynamic_dependency=absent\n'
