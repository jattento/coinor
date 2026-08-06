#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
package_path="$repo_root/Tools/CoinorHookRelay"
hooks_dir="$HOME/.grok/hooks"
hook_file="$hooks_dir/coinor.json"
relay_file="$hooks_dir/coinor-hook-relay"
socket_path="$HOME/Library/Application Support/Coinor/hook.sock"

mkdir -p "$hooks_dir"

if [ -e "$hook_file" ]; then
  python3 - "$hook_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

owner = document.get("_coinor")
if not isinstance(owner, dict) or owner.get("schemaVersion") != 1:
    raise SystemExit(
        f"Refusing to overwrite non-Coinor hook registration: {sys.argv[1]}"
    )
PY
elif [ -e "$relay_file" ]; then
  printf 'Refusing to overwrite unowned relay: %s\n' "$relay_file" >&2
  exit 1
fi

swift build --configuration release --package-path "$package_path"
relay_source=$(
  swift build \
    --configuration release \
    --package-path "$package_path" \
    --show-bin-path
)/coinor-hook-relay

relay_temporary="$relay_file.tmp.$$"
hook_temporary="$hook_file.tmp.$$"
trap 'rm -f "$relay_temporary" "$hook_temporary"' EXIT HUP INT TERM

install -m 755 "$relay_source" "$relay_temporary"
mv -f "$relay_temporary" "$relay_file"

python3 - "$hook_temporary" "$relay_file" "$socket_path" <<'PY'
import json
import sys

destination, relay, socket = sys.argv[1:]
handler = {
    "type": "command",
    "command": relay,
    "timeout": 2,
    "env": {
        "COINOR_HOOK_SOCKET": socket,
        "COINOR_HOOK_TIMEOUT_MS": "150",
    },
}
document = {
    "_coinor": {
        "schemaVersion": 1,
        "purpose": "Coinor lifecycle relay",
    },
    "hooks": {
        event: [{"hooks": [handler]}]
        for event in (
            "SessionStart",
            "SubagentStart",
            "SubagentStop",
            "SessionEnd",
        )
    },
}

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY

chmod 644 "$hook_temporary"
mv -f "$hook_temporary" "$hook_file"

python3 -m json.tool "$hook_file" >/dev/null

printf 'Installed Coinor hook registration: %s\n' "$hook_file"
printf 'Installed Coinor hook relay: %s\n' "$relay_file"
printf 'Configured Coinor hook socket: %s\n' "$socket_path"
