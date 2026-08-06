#!/bin/sh
set -eu

spike_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$spike_dir/../.." && pwd)
relay_package="$repo_root/Tools/CoinorHookRelay"

swift build --configuration release --package-path "$relay_package"
relay_bin=$(
  swift build \
    --configuration release \
    --package-path "$relay_package" \
    --show-bin-path
)/coinor-hook-relay

swift test --package-path "$relay_package"
COINOR_HOOK_RELAY_EXECUTABLE="$relay_bin" \
  swift test --package-path "$spike_dir"
