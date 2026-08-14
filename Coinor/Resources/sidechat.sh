#!/bin/sh
# Fork the current Grok session into a new Conan Code tab.
#
#   CONAN_CODE_REQUEST_ID=<uuid-literal> sh sidechat.sh [tab label...]
#
# Runs `grok --resume <current-session> --fork-session --session-id <new-uuid>`
# in a freshly created Conan Code managed tab, so the fork gets a real copy of
# the conversation under a new session ID instead of a second client on the
# same one.
set -u

label=${*:-sidechat}

client=${CONAN_CODE_CONTROL_CLIENT:-}
if [ -z "$client" ] || [ ! -x "$client" ]; then
  echo "sidechat: not running inside Conan Code" >&2
  exit 1
fi

# Conan Code authorizes tab creation by matching the request ID it saw in the
# agent's own `run_terminal_command` text against the one the client sends, so
# the literal has to come in from the invoking command line. A value minted
# inside this script would never have been observed and is always rejected.
request_id=${CONAN_CODE_REQUEST_ID:-}
if [ -z "$request_id" ]; then
  echo "sidechat: CONAN_CODE_REQUEST_ID is required; invoke this script as" \
    "CONAN_CODE_REQUEST_ID=<uuid-literal> sh sidechat.sh [label]" >&2
  exit 1
fi

for bin in jq uuidgen; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "sidechat: $bin not found in PATH" >&2
    exit 1
  }
done

# Conan Code launches every Grok it owns from an absolute path, and a tab shell
# starts with the Finder PATH, so the fork is resolved the same way.
grok=${COINOR_GROK_EXECUTABLE:-$HOME/bin/grok}
if [ ! -x "$grok" ]; then
  grok=$(command -v grok 2>/dev/null) || grok=
fi
[ -n "$grok" ] && [ -x "$grok" ] || {
  echo "sidechat: no executable grok found at ~/bin/grok or on PATH" >&2
  exit 1
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Grok exposes the session ID only to hooks ($GROK_SESSION_ID), never to tool
# processes, and under Conan Code's leader every session shares one process --
# so identity has to come from the roster. Live sessions rooted at this cwd are
# the candidates; the one whose transcript was written most recently is the one
# running this command.
roster=$HOME/.grok/active_sessions.json
[ -f "$roster" ] || {
  echo "sidechat: $roster missing" >&2
  exit 1
}

sid=
newest=
for entry in $(jq -r --arg c "$PWD" \
  '.[] | select(.cwd == $c) | "\(.session_id):\(.pid)"' "$roster"); do
  s=${entry%%:*}
  p=${entry##*:}
  kill -0 "$p" 2>/dev/null || continue
  f=$(ls -t "$HOME"/.grok/sessions/*/"$s"/updates.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  m=$(mtime "$f")
  [ -n "$m" ] || continue
  if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then
    newest=$m
    sid=$s
  fi
done
[ -n "$sid" ] || {
  echo "sidechat: no live Grok session found for $PWD" >&2
  exit 1
}

# Naming the fork up front (`--session-id` is only legal together with
# `--fork-session`) is what lets the tab carry a name derived from the child
# rather than a guess. Tail, not head: a UUIDv7 leads with a timestamp.
fork=$(uuidgen | tr 'A-Z' 'a-z')
name=sc-$(printf %s "$fork" | tr -d - | tail -c 8)

created=$("$client" create \
  --request-id "$request_id" \
  --title "$label" \
  --cwd "$PWD") || {
  echo "sidechat: tab create failed" >&2
  exit 1
}
tab=$(printf %s "$created" | jq -r '.result.tabID // empty')
capability=$(printf %s "$created" | jq -r '.result.capability // empty')
[ -n "$tab" ] && [ -n "$capability" ] || {
  echo "sidechat: tab create returned no tab: $created" >&2
  exit 1
}

# `create` returns before the new tab's shell reaches its prompt, and a managed
# command sent before that is refused.
i=0
ready=
while [ "$i" -lt 30 ]; do
  state=$("$client" status --tab "$tab" --capability "$capability" 2>/dev/null |
    jq -r '.result.state // empty')
  case $state in
  idle)
    ready=1
    break
    ;;
  exited)
    echo "sidechat: tab $tab exited before the fork could start" >&2
    exit 1
    ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ -n "$ready" ] || {
  echo "sidechat: tab $tab never became ready" >&2
  "$client" close --tab "$tab" --capability "$capability" >/dev/null 2>&1
  exit 1
}

# Not `exec`: leaving the tab's shell in place means the tab returns to idle
# when the fork ends, instead of dying with it.
quoted_grok=$(printf "'%s'" "$(printf %s "$grok" | sed "s/'/'\\\\''/g")")
"$client" execute --tab "$tab" --capability "$capability" \
  --command "$quoted_grok --resume $sid --fork-session --session-id $fork" \
  >/dev/null || {
  echo "sidechat: could not start the fork in $tab" >&2
  "$client" close --tab "$tab" --capability "$capability" >/dev/null 2>&1
  exit 1
}

printf '%s (%s)\n  tab     %s\n  parent  %s\n  fork    %s\n' \
  "$label" "$name" "$tab" "$sid" "$fork"
