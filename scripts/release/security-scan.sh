#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/coinor-security-scan.XXXXXX")"
APP="${1:-}"

cleanup() {
  rm -rf "$SNAPSHOT"
}
trap cleanup EXIT

command -v gitleaks >/dev/null 2>&1 || {
  echo "error: gitleaks is required" >&2
  exit 1
}

scan_for_local_home_path() {
  local root="$1"
  local matches="$SNAPSHOT/local-home-path-matches.txt"

  while IFS= read -r -d '' file; do
    if strings -a "$file" 2>/dev/null | grep -F "$HOME" > "$matches"; then
      echo "error: release bundle contains the local home path" >&2
      printf 'file: %s\n' "$file" >&2
      sed -n '1p' "$matches" >&2
      return 1
    fi
  done < <(find "$root" -type f -print0)
}

gitleaks git "$ROOT" --log-opts='--all' --no-banner --redact=100

while IFS= read -r -d '' path; do
  source_path="$ROOT/$path"
  [[ -f "$source_path" ]] || continue
  mkdir -p "$SNAPSHOT/$(dirname "$path")"
  cp -p "$source_path" "$SNAPSHOT/$path"
done < <(git -C "$ROOT" ls-files -z -c -o --exclude-standard)

gitleaks dir "$SNAPSHOT" --no-banner --redact=100
scan_for_local_home_path "$SNAPSHOT"

if [[ -n "$APP" ]]; then
  [[ -d "$APP" ]] || {
    echo "error: application bundle not found: $APP" >&2
    exit 1
  }

  gitleaks dir "$APP" --no-banner --redact=100

  scan_for_local_home_path "$APP"
fi

echo "Coinor security scan passed."
