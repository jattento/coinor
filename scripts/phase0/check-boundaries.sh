#!/bin/sh

set -eu

coinor_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
grok_build_root=/Users/jattentokeyway/projects/github.com/jattento/grok-build
expected_status="$coinor_root/docs/baselines/grok-build-status.txt"
actual_status=$(mktemp)
runtime_status=$(mktemp)
trap 'rm -f "$actual_status" "$runtime_status"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$(git -C "$coinor_root" rev-parse --show-toplevel)" = "$coinor_root" ] ||
  fail "Coinor is not a standalone Git repository."

[ -x "$HOME/bin/grok" ] ||
  fail "The configured Grok executable is not available at $HOME/bin/grok."

resolved_grok=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$HOME/bin/grok")
[ "${resolved_grok#/}" != "$resolved_grok" ] ||
  fail "Grok did not resolve to an absolute path."

runtime_root=$(git -C "$(dirname "$resolved_grok")" rev-parse --show-toplevel 2>/dev/null) ||
  fail "The resolved Grok executable is not inside a Git worktree."
expected_runtime_head=$(cat "$coinor_root/docs/baselines/grok-runtime-head.txt")
actual_runtime_head=$(git -C "$runtime_root" rev-parse HEAD)
[ "$actual_runtime_head" = "$expected_runtime_head" ] ||
  fail "The Grok runtime worktree revision changed from the Phase 0 baseline."

git -C "$runtime_root" status --short >"$runtime_status"
if ! diff -u "$coinor_root/docs/baselines/grok-runtime-status.txt" "$runtime_status"; then
  fail "The Grok runtime worktree no longer matches the Phase 0 baseline."
fi

git -C "$grok_build_root" status --short >"$actual_status"
if ! diff -u "$expected_status" "$actual_status"; then
  fail "grok-build no longer matches the recorded initial status."
fi

config_file="$HOME/.grok/config.toml"
if [ -f "$config_file" ] &&
  grep -Eq '^[[:space:]]*use_leader[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$' "$config_file"; then
  fail "Global Grok leader mode is enabled; Coinor must use only its private socket."
fi

case "$(uname -s)" in
  Darwin) ;;
  *) fail "Coinor Phase 0 must run on macOS." ;;
esac

case "$(uname -m)" in
  arm64) ;;
  *) fail "This Phase 0 baseline expects Apple Silicon." ;;
esac

printf 'PASS: repository boundaries are intact.\n'
printf 'Grok executable: %s\n' "$resolved_grok"
printf 'Grok version: '
"$HOME/bin/grok" --version
