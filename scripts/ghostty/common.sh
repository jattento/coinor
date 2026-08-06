#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

readonly GHOSTTY_TAG="v1.3.1"
readonly GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
readonly GHOSTTY_REPOSITORY="https://github.com/ghostty-org/ghostty.git"
readonly GHOSTTY_VERSION="1.3.1"

readonly ZIG_VERSION="0.15.2"
readonly ZIG_ARM64_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
readonly ZIG_X86_64_SHA256="375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f"

readonly CACHE_ROOT="$SCRIPT_DIR/.cache"
readonly GHOSTTY_SOURCE="$CACHE_ROOT/source"
readonly GHOSTTY_ZIG_CACHE="${COINOR_GHOSTTY_ZIG_CACHE:-$CACHE_ROOT/zig-cache}"
readonly GHOSTTY_ZIG_GLOBAL_CACHE="${COINOR_GHOSTTY_ZIG_GLOBAL_CACHE:-$CACHE_ROOT/zig-global-cache}"

readonly SPIKE_ROOT="$REPO_ROOT/Spikes/GhosttySpike"
readonly BUILD_ROOT="$SPIKE_ROOT/.build"
readonly GHOSTTY_INSTALL_PREFIX="$BUILD_ROOT/ghostty-install"
readonly GHOSTTY_ARTIFACT_ROOT="$BUILD_ROOT/ghostty-artifact"
readonly GHOSTTY_XCFRAMEWORK="$GHOSTTY_ARTIFACT_ROOT/GhosttyKit.xcframework"
readonly GHOSTTY_RESOURCES="$GHOSTTY_ARTIFACT_ROOT/Resources"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}
