#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
default_app="$repo_root/.build/DerivedData/Build/Products/Debug/Coinor.app"
app_bundle=${1:-${COINOR_APP_BUNDLE:-$default_app}}
hooks_dir="$HOME/.grok/hooks"
hook_file="$hooks_dir/coinor.json"
relay_file="$hooks_dir/coinor-hook-relay"
socket_path="$HOME/Library/Application Support/Coinor/hook.sock"
bundled_relay="$app_bundle/Contents/Resources/coinor-hook-relay"

if [ "$#" -gt 1 ]; then
  printf 'Usage: %s [Coinor.app]\n' "$0" >&2
  exit 2
fi

[ -d "$app_bundle" ] || {
  printf 'Coinor app bundle is missing: %s\n' "$app_bundle" >&2
  printf 'Build Coinor first or pass an explicit Coinor.app path.\n' >&2
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

relay_temporary="$relay_file.tmp.$$"
hook_temporary="$hook_file.tmp.$$"
trap 'rm -f "$relay_temporary" "$hook_temporary"' EXIT HUP INT TERM

install -m 755 "$bundled_relay" "$relay_temporary"
cmp -s "$bundled_relay" "$relay_temporary" || {
  printf 'Installed relay copy does not match the Coinor app bundle.\n' >&2
  exit 1
}
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
printf 'Installed from Coinor app: %s\n' "$app_bundle"
printf 'Configured Coinor hook socket: %s\n' "$socket_path"
