#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
hook_file="$HOME/.grok/hooks/coinor.json"
relay_file="$HOME/.grok/hooks/coinor-hook-relay"
relay_build=$(
  swift build \
    --configuration release \
    --package-path "$repo_root/Tools/CoinorHookRelay" \
    --show-bin-path
)/coinor-hook-relay

[ -x "$relay_file" ] || {
  printf 'Coinor hook relay is missing or not executable: %s\n' "$relay_file" >&2
  exit 1
}

[ -x "$relay_build" ] || {
  printf 'Coinor hook relay release build is missing: %s\n' "$relay_build" >&2
  exit 1
}

cmp -s "$relay_build" "$relay_file" || {
  printf 'Installed Coinor hook relay is out of date; run scripts/hooks/install.sh\n' >&2
  exit 1
}

python3 - "$hook_file" "$relay_file" <<'PY'
import json
import sys

hook_path, expected_relay = sys.argv[1:]
with open(hook_path, encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("_coinor", {}).get("schemaVersion") != 1:
    raise SystemExit("Coinor ownership marker is missing")

expected_events = {
    "SessionStart",
    "SubagentStart",
    "SubagentStop",
    "SessionEnd",
}
hooks = document.get("hooks", {})
if set(hooks) != expected_events:
    raise SystemExit(f"Unexpected Coinor hook events: {sorted(hooks)}")

commands = {
    handler["command"]
    for groups in hooks.values()
    for group in groups
    for handler in group.get("hooks", [])
}
if commands != {expected_relay}:
    raise SystemExit(f"Unexpected Coinor relay commands: {sorted(commands)}")

for groups in hooks.values():
    for group in groups:
        for handler in group.get("hooks", []):
            socket = handler.get("env", {}).get("COINOR_HOOK_SOCKET", "")
            if not socket.endswith("/Library/Application Support/Coinor/hook.sock"):
                raise SystemExit(f"Unexpected Coinor hook socket: {socket}")
PY

printf 'PASS: Coinor hook registration is valid.\n'
