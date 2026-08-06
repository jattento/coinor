#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command curl
require_command git
require_command shasum
require_command tar

case "$(uname -m)" in
  arm64)
    zig_arch="aarch64"
    zig_sha256="$ZIG_ARM64_SHA256"
    ;;
  x86_64)
    zig_arch="x86_64"
    zig_sha256="$ZIG_X86_64_SHA256"
    ;;
  *)
    die "unsupported macOS architecture: $(uname -m)"
    ;;
esac

zig_directory="$CACHE_ROOT/zig-${zig_arch}-macos-${ZIG_VERSION}"
zig_archive="${zig_directory}.tar.xz"
zig_url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-macos-${ZIG_VERSION}.tar.xz"

mkdir -p "$CACHE_ROOT"

if [[ ! -f "$zig_archive" ]] || [[ "$(sha256_file "$zig_archive")" != "$zig_sha256" ]]; then
  rm -f "$zig_archive"
  curl --fail --location --retry 3 --output "$zig_archive" "$zig_url"
fi

actual_zig_sha="$(sha256_file "$zig_archive")"
[[ "$actual_zig_sha" == "$zig_sha256" ]] || \
  die "Zig archive checksum mismatch: expected $zig_sha256, got $actual_zig_sha"

if [[ ! -x "$zig_directory/zig" ]]; then
  rm -rf "$zig_directory"
  tar -xJf "$zig_archive" -C "$CACHE_ROOT"
fi

actual_zig_version="$("$zig_directory/zig" version)"
[[ "$actual_zig_version" == "$ZIG_VERSION" ]] || \
  die "unexpected Zig version: expected $ZIG_VERSION, got $actual_zig_version"

if [[ ! -d "$GHOSTTY_SOURCE/.git" ]]; then
  rm -rf "$GHOSTTY_SOURCE"
  git clone --depth 1 --branch "$GHOSTTY_TAG" "$GHOSTTY_REPOSITORY" "$GHOSTTY_SOURCE"
fi

tag_commit="$(git -C "$GHOSTTY_SOURCE" rev-parse "${GHOSTTY_TAG}^{commit}" 2>/dev/null || true)"
if [[ "$tag_commit" != "$GHOSTTY_COMMIT" ]]; then
  git -C "$GHOSTTY_SOURCE" fetch --force --depth 1 origin \
    "refs/tags/${GHOSTTY_TAG}:refs/tags/${GHOSTTY_TAG}"
  tag_commit="$(git -C "$GHOSTTY_SOURCE" rev-parse "${GHOSTTY_TAG}^{commit}")"
fi

[[ "$tag_commit" == "$GHOSTTY_COMMIT" ]] || \
  die "Ghostty tag mismatch: expected $GHOSTTY_COMMIT, got $tag_commit"

if [[ "$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)" != "$GHOSTTY_COMMIT" ]]; then
  git -C "$GHOSTTY_SOURCE" checkout --detach "$GHOSTTY_COMMIT"
fi

git -C "$GHOSTTY_SOURCE" diff --quiet -- . ':!macos/GhosttyKit.xcframework' || \
  die "tracked Ghostty source files are modified"

printf '%s\n' "$zig_directory/zig"
