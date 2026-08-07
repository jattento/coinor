#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
default_app="$repo_root/.build/DerivedData/Build/Products/Debug/Coinor.app"
app_bundle=${1:-${COINOR_APP_BUNDLE:-$default_app}}
hook_file="$HOME/.grok/hooks/coinor.json"
relay_file="$HOME/.grok/hooks/coinor-hook-relay"
bundled_relay="$app_bundle/Contents/Resources/coinor-hook-relay"
socket_path="$HOME/Library/Application Support/Coinor/hook.sock"

if [ "$#" -gt 1 ]; then
  printf 'Usage: %s [Coinor.app]\n' "$0" >&2
  exit 2
fi

[ -d "$app_bundle" ] || {
  printf 'Coinor app bundle is missing: %s\n' "$app_bundle" >&2
  exit 1
}

[ -x "$bundled_relay" ] || {
  printf 'Bundled Coinor hook relay is missing or not executable: %s\n' "$bundled_relay" >&2
  exit 1
}

codesign --verify --deep --strict "$app_bundle" || {
  printf 'Coinor app bundle has an invalid code signature: %s\n' "$app_bundle" >&2
  exit 1
}

[ -x "$relay_file" ] || {
  printf 'Coinor hook relay is missing or not executable: %s\n' "$relay_file" >&2
  exit 1
}

[ -f "$hook_file" ] || {
  printf 'Coinor hook registration is missing: %s\n' "$hook_file" >&2
  exit 1
}

cmp -s "$bundled_relay" "$relay_file" || {
  printf 'Installed Coinor hook relay does not match %s\n' "$app_bundle" >&2
  printf 'Run scripts/hooks/install.sh with this Coinor.app bundle.\n' >&2
  exit 1
}

python3 - "$hook_file" "$relay_file" "$socket_path" <<'PY'
import json
import sys

hook_path, expected_relay, expected_socket = sys.argv[1:]
try:
    with open(hook_path, encoding="utf-8") as handle:
        document = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Invalid Coinor hook registration: {error}")

owner = document.get("_coinor")
if not isinstance(owner, dict):
    raise SystemExit("Coinor ownership marker is missing")
if owner.get("schemaVersion") != 1:
    raise SystemExit("Coinor hook schema version must be 1")
if owner.get("purpose") != "Coinor lifecycle relay":
    raise SystemExit("Coinor hook ownership purpose is invalid")

expected_events = [
    "SessionStart",
    "SubagentStart",
    "SubagentStop",
    "SessionEnd",
]
hooks = document.get("hooks", {})
if not isinstance(hooks, dict) or set(hooks) != set(expected_events):
    raise SystemExit(f"Unexpected Coinor hook events: {sorted(hooks)}")

for event in expected_events:
    groups = hooks[event]
    if not isinstance(groups, list) or len(groups) != 1:
        raise SystemExit(f"{event} must contain exactly one hook group")
    handlers = groups[0].get("hooks") if isinstance(groups[0], dict) else None
    if not isinstance(handlers, list) or len(handlers) != 1:
        raise SystemExit(f"{event} must contain exactly one hook handler")

    handler = handlers[0]
    if not isinstance(handler, dict):
        raise SystemExit(f"{event} hook handler is invalid")
    if handler.get("type") != "command":
        raise SystemExit(f"{event} hook type must be command")
    if handler.get("command") != expected_relay:
        raise SystemExit(f"{event} has an unexpected relay command")
    if handler.get("timeout") != 2:
        raise SystemExit(f"{event} hook timeout must be 2 seconds")

    environment = handler.get("env")
    if not isinstance(environment, dict):
        raise SystemExit(f"{event} hook environment is missing")
    if set(environment) != {"COINOR_HOOK_SOCKET", "COINOR_HOOK_TIMEOUT_MS"}:
        raise SystemExit(f"{event} hook environment has unexpected keys")
    if environment.get("COINOR_HOOK_SOCKET") != expected_socket:
        raise SystemExit(f"{event} has an unexpected Coinor hook socket")
    if environment.get("COINOR_HOOK_TIMEOUT_MS") != "150":
        raise SystemExit(f"{event} relay timeout must be 150 milliseconds")
PY

printf 'PASS: Coinor hook registration is valid.\n'
printf 'PASS: Installed relay matches %s\n' "$app_bundle"
