#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

source_root="$GHOSTTY_ARTIFACT_ROOT"
destination_root="$GHOSTTY_APP_ARTIFACT_ROOT"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--source-root PATH] [--destination-root PATH]

Install the Phase 0 Ghostty artifact into the directory consumed by Xcode.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      [[ $# -ge 2 ]] || die "--source-root requires a path"
      source_root="$2"
      shift 2
      ;;
    --destination-root)
      [[ $# -ge 2 ]] || die "--destination-root requires a path"
      destination_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

temporary_root="$destination_root.tmp.$$"

require_command ditto

"$SCRIPT_DIR/verify.sh" --artifact-root "$source_root"

rm -rf "$temporary_root"
mkdir -p "$temporary_root"
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

ditto "$source_root/GhosttyKit.xcframework" \
  "$temporary_root/GhosttyKit.xcframework"
ditto "$source_root/Resources" "$temporary_root/Resources"
cp "$source_root/manifest.txt" "$temporary_root/manifest.txt"

xcframework_sha="$(sha256_tree "$temporary_root/GhosttyKit.xcframework")"
resources_sha="$(sha256_tree "$temporary_root/Resources")"
manifest_tmp="$temporary_root/manifest.txt.tmp"
awk -F= '$1 != "xcframework_sha256" && $1 != "resources_sha256" { print }' \
  "$temporary_root/manifest.txt" > "$manifest_tmp"
printf 'xcframework_sha256=%s\n' "$xcframework_sha" >> "$manifest_tmp"
printf 'resources_sha256=%s\n' "$resources_sha" >> "$manifest_tmp"
mv "$manifest_tmp" "$temporary_root/manifest.txt"

"$SCRIPT_DIR/verify.sh" --artifact-root "$temporary_root"

rm -rf "$destination_root"
mv "$temporary_root" "$destination_root"

"$SCRIPT_DIR/verify.sh" --artifact-root "$destination_root"

if [[ "$destination_root" == "$GHOSTTY_APP_ARTIFACT_ROOT" ]]; then
  cp "$destination_root/manifest.txt" \
    "$REPO_ROOT/Coinor/Resources/GhosttyArtifactManifest.txt"
fi

printf 'Installed verified Ghostty artifact: %s\n' "$destination_root"
