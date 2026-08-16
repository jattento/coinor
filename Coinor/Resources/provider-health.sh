#!/bin/bash
# Conan Code — provider health check and repair.
#
# Verifies every AI provider this machine is configured to use, and repairs what
# can be repaired without a human. Reads credentials only to report their type
# and expiry; it never prints, copies, or transmits a secret value.
#
# Usage:
#   provider-health.sh check            human-readable report (default)
#   provider-health.sh check --json     machine-readable report
#   provider-health.sh fix              apply the safe automatic repairs, then re-check
#   provider-health.sh remote <alias>   run `check` on another Mac over SSH
#   provider-health.sh check --with-remote [alias]
#                                       local check, then the same check on the
#                                       other Mac when it is reachable
#
# Exit codes: 0 healthy, 1 degraded (something needs attention), 2 broken
# (the proxy every model depends on is down).

set -uo pipefail

JSON=0
WITH_REMOTE=0
REMOTE_ALIAS=""
CMD="check"

LOGIN_PROVIDER=""
LOGIN_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    check|fix) CMD="$1"; shift ;;
    login|login-wait|login-paste|login-cancel)
      CMD="$1"; LOGIN_PROVIDER="${2-}"; LOGIN_ARG="${3-}"
      shift; [ $# -gt 0 ] && shift; [ $# -gt 0 ] && shift ;;
    remote) CMD="remote"; REMOTE_ALIAS="${2-}"; shift 2 2>/dev/null || shift ;;
    --json) JSON=1; shift ;;
    --with-remote) WITH_REMOTE=1; [ -n "${2-}" ] && case "$2" in -*) ;; *) REMOTE_ALIAS="$2"; shift ;; esac; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done

# ---------------------------------------------------------------- discovery --
# Nothing below is hardcoded to one machine: Homebrew prefix, the launchd label,
# the proxy port and the SSH alias are all discovered, so the same script runs
# unchanged on the personal and the work Mac.

# How to invoke this script again, so the repairs it prints can be run verbatim.
# Abbreviated to ~ so a repair line stays readable in the report.
case "$0" in
  /*) SELF_PATH="$0" ;;
  *)  SELF_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac
SELF="sh $(printf '%s' "$SELF_PATH" | sed "s|^$HOME|~|")"

find_bin() { command -v "$1" 2>/dev/null; }

# Explicit overrides win over discovery. They keep the script honest on a Mac
# that puts these somewhere else, and let a test run it against a machine that
# has no provider tooling at all.
CLIPROXY_BIN="${PROVIDER_HEALTH_CLIPROXY_BIN-}"
if [ -z "${PROVIDER_HEALTH_CLIPROXY_BIN+set}" ]; then
  CLIPROXY_BIN="$(find_bin cliproxyapi)"
  if [ -z "$CLIPROXY_BIN" ]; then
    for p in /opt/homebrew/opt/cliproxyapi/bin/cliproxyapi /usr/local/opt/cliproxyapi/bin/cliproxyapi; do
      [ -x "$p" ] && CLIPROXY_BIN="$p" && break
    done
  fi
fi

CLIPROXY_CONF="${PROVIDER_HEALTH_CLIPROXY_CONF-}"
if [ -z "${PROVIDER_HEALTH_CLIPROXY_CONF+set}" ]; then
  for p in /opt/homebrew/etc/cliproxyapi.conf /usr/local/etc/cliproxyapi.conf "$HOME/.cli-proxy-api/config.yaml"; do
    [ -f "$p" ] && CLIPROXY_CONF="$p" && break
  done
fi
[ -n "$CLIPROXY_CONF" ] && [ ! -f "$CLIPROXY_CONF" ] && CLIPROXY_CONF=""

conf_value() { # conf_value <key> ; top-level "key: value" from the YAML-ish conf
  [ -n "$CLIPROXY_CONF" ] || return 0
  sed -n "s/^${1}:[[:space:]]*//p" "$CLIPROXY_CONF" 2>/dev/null | head -1 | tr -d '"' | tr -d "'"
}

PROXY_PORT="$(conf_value port)"
[ -n "$PROXY_PORT" ] || PROXY_PORT=8318
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"

AUTH_DIR="$(conf_value auth-dir)"
AUTH_DIR="${AUTH_DIR/#\~/$HOME}"
[ -n "$AUTH_DIR" ] && [ -d "$AUTH_DIR" ] || AUTH_DIR="$HOME/.cli-proxy-api"

LAUNCHD_LABEL="$(launchctl list 2>/dev/null | awk '/cliproxy/ {print $3; exit}')"

GROK_HOME="${GROK_HOME:-$HOME/.grok}"
GROK_CONFIG="$GROK_HOME/config.toml"
ROUTER_CONFIG="$GROK_HOME/subagent-router.toml"
CODEXBAR="$(find_bin codexbar)"

# ------------------------------------------------------------------ helpers --
STATUS=0            # worst status seen; 0 ok, 1 degraded, 2 broken
FINDINGS=""         # newline-separated "level|area|subject|detail|repair"

note() { # note <ok|warn|fail> <area> <subject> <detail> [repair]
  FINDINGS="${FINDINGS}${1}|${2}|${3}|${4}|${5-}
"
  case "$1" in
    fail) [ "$2" = "proxy" ] && STATUS=2 || { [ $STATUS -lt 1 ] && STATUS=1; } ;;
    warn) [ $STATUS -lt 1 ] && STATUS=1 ;;
  esac
  return 0
}

have_python() { command -v python3 >/dev/null 2>&1; }

# --------------------------------------------------------------- 1. proxy ----
check_proxy() {
  if [ -z "$CLIPROXY_BIN" ] && [ -z "$CLIPROXY_CONF" ]; then
    note fail proxy cliproxyapi "not installed on this machine" \
      "brew install cliproxyapi"
    return
  fi

  local listening models
  listening=$(lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -1)
  if [ -z "$listening" ]; then
    note fail proxy "port $PROXY_PORT" "nothing is listening; every configured model routes through this proxy" \
      "${LAUNCHD_LABEL:+launchctl kickstart -k gui/$(id -u)/$LAUNCHD_LABEL}"
    return
  fi

  models=$(curl -s -m 10 "$PROXY_URL/v1/models" 2>/dev/null \
    | { have_python && python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("data",[])))
except Exception: print(0)' || echo 0; })

  if [ "${models:-0}" -gt 0 ]; then
    note ok proxy "cliproxyapi:$PROXY_PORT" "serving $models models"
  else
    note fail proxy "cliproxyapi:$PROXY_PORT" "listening but /v1/models returned no catalog" \
      "${LAUNCHD_LABEL:+launchctl kickstart -k gui/$(id -u)/$LAUNCHD_LABEL}"
  fi
}

# --------------------------------------------------- 2. proxy credentials ----
# The login flag differs per provider; map the credential file to the exact
# command that repairs it. These flows are interactive by design (OAuth or a
# device code), so they are reported, never run unattended.
login_flag_for() {
  case "$1" in
    antigravity)    echo "-antigravity-login" ;;
    claude)         echo "-claude-login" ;;
    codex)          echo "-codex-login" ;;
    gemini|gemini-cli|geminicli) echo "-geminicli-login" ;;
    github-copilot|copilot) echo "-copilot-login" ;;
    kimi)           echo "-kimi-login" ;;
    *)              echo "" ;;
  esac
}

# codexbar, cliproxyapi and the credential filenames each use their own name
# for the same provider. Everything downstream repairs by the cliproxyapi name,
# so normalise here rather than in three places.
canonical_provider() {
  case "$1" in
    gemini|gemini-cli|geminicli) echo "geminicli" ;;
    github-copilot|copilot)      echo "copilot" ;;
    opencodego)                  echo "opencode-go" ;;
    *)                           echo "$1" ;;
  esac
}

# The repair a caller should actually run. Emitting `cliproxyapi -x-login`
# here would be wrong twice over: it hangs when run directly, and it
# contradicts this skill's own instructions.
repair_for() {
  local provider canonical flag
  provider="$1"
  canonical=$(canonical_provider "$provider")
  flag=$(login_flag_for "$canonical")
  if [ -n "$flag" ]; then
    echo "$SELF login $canonical   (drive the browser, then: $SELF login-wait $canonical)"
    return
  fi
  case "$canonical" in
    opencode|opencode-go)
      echo "api key, not OAuth: check the openai-compatibility api-key in ${CLIPROXY_CONF:-the cliproxyapi config}" ;;
    *)
      echo "no automatic repair known for '$provider'" ;;
  esac
}

check_credentials() {
  if [ ! -d "$AUTH_DIR" ]; then
    note warn credentials "$AUTH_DIR" "auth directory does not exist" \
      "run the provider login flows to create it"
    return
  fi

  have_python || { note warn credentials python3 "python3 unavailable; cannot read expiry" ""; return; }

  local f
  for f in "$AUTH_DIR"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.backup.*) continue ;; esac

    # Emits "<provider> <state> <detail>". Only metadata leaves python.
    local parsed provider state detail flag
    parsed=$(python3 - "$f" <<'PY'
import json, sys, datetime
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print("unknown unreadable malformed-json"); sys.exit()
prov = d.get("type") or d.get("provider") or "unknown"
key = next((k for k in d if "expire" in k.lower() or "expiry" in k.lower()), None)
raw = d.get(key) if key else None
if not raw:
    print(f"{prov} unknown no-expiry-field"); sys.exit()
try:
    s = str(raw).replace("Z", "+00:00")
    exp = datetime.datetime.fromisoformat(s)
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=datetime.timezone.utc)
except Exception:
    print(f"{prov} unknown unparseable-expiry"); sys.exit()
now = datetime.datetime.now(datetime.timezone.utc)
days = (exp - now).total_seconds() / 86400
stamp = exp.date().isoformat()
if days < 0:
    print(f"{prov} expired expired-{abs(int(days))}d-ago-on-{stamp}")
elif days < 1:
    print(f"{prov} expiring expires-today-{stamp}")
else:
    print(f"{prov} ok valid-until-{stamp}")
PY
)
    provider=$(echo "$parsed" | awk '{print $1}')
    state=$(echo "$parsed" | awk '{print $2}')
    detail=$(echo "$parsed" | awk '{print $3}')
    flag=$(login_flag_for "$provider")

    # Several accounts can share a provider, so name the account too or the
    # report shows identical-looking rows and you cannot tell which to fix.
    # The filename prefix does not always match the provider name inside the
    # file (`geminicli-*.json` holds type `gemini-cli`), so strip whichever
    # prefix is actually there and fall back to the bare filename. Two rows
    # that read the same are worse than a long label.
    local account subject base
    base=$(basename "$f" .json)
    account=${base#"$provider"-}
    [ "$account" = "$base" ] && account=${base#"${provider//-/}"-}
    [ "$account" = "$base" ] && account=$base
    subject="$provider"
    [ -n "$account" ] && subject="$provider/$account"

    # A short-lived access token that expired minutes ago is not broken: its
    # refresh token renews it on the next call. Only a credential that is
    # stale by more than a day is worth waking someone for.
    local age
    age=$(echo "$detail" | sed -n 's/^expired-\([0-9]*\)d-ago.*/\1/p')

    case "$state" in
      ok)       note ok   credentials "$subject" "$detail" ;;
      expiring) note ok   credentials "$subject" "$detail (short-lived; the refresh token renews it)" ;;
      expired)
        if [ -n "$age" ] && [ "$age" -lt 1 ]; then
          note ok credentials "$subject" "$detail (short-lived; the refresh token renews it)"
        else
          note fail credentials "$subject" "$detail" "$(repair_for "$provider")"
        fi
        ;;
      # A credential with no expiry field is a refresh-token or API-key style
      # secret: nothing local can prove it still works, so it is reported as
      # informational and the live proof is the codexbar and proxy checks.
      *)        note ok   credentials "$subject" "$detail (liveness proven by codexbar/proxy, not by the file)" ;;
    esac
  done
}

# ------------------------------------------------------------- 3. codexbar ---
check_codexbar() {
  if [ -z "$CODEXBAR" ]; then
    note warn codexbar codexbar "not installed; quota is unknown to the router" \
      "brew install --cask codexbar"
    return
  fi
  have_python || { note warn codexbar python3 "python3 unavailable" ""; return; }

  local raw summary
  raw=$(mktemp -t provider-health-codexbar) || return
  "$CODEXBAR" usage --format json >"$raw" 2>/dev/null
  [ -s "$raw" ] || { rm -f "$raw"; note warn codexbar usage "returned nothing" "$CODEXBAR usage --format json"; return; }

  # `python3 -c` rather than a heredoc: with `python3 - <<PY` the program comes
  # from stdin, so redirecting the payload in as well makes python execute the
  # JSON instead of parsing it. Single quotes keep the shell out of the program.
  summary=$(python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit()
if isinstance(entries, dict):
    entries = [entries]
for e in entries:
    p = e.get("provider") or "unknown"
    err = e.get("error")
    if err:
        msg = str(err.get("message", "error")).replace("\n", " ").replace("|", "/")[:88]
        print("%s fail %s" % (p, msg))
        continue
    u = e.get("usage") or {}
    parts = []
    for slot in ("primary", "secondary", "tertiary"):
        w = u.get(slot)
        if isinstance(w, dict) and w.get("usedPercent") is not None:
            parts.append("%s=%d%%" % (slot[0], round(w["usedPercent"])))
    print("%s ok %s" % (p, " ".join(parts) if parts else "reachable"))
' <"$raw" 2>/dev/null)
  rm -f "$raw"
  [ -n "$summary" ] || { note warn codexbar usage "output was not parseable JSON" "$CODEXBAR usage --format json"; return; }

  local line provider state detail
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    provider=$(printf '%s' "$line" | cut -d' ' -f1)
    state=$(printf '%s' "$line" | cut -d' ' -f2)
    detail=$(printf '%s' "$line" | cut -d' ' -f3-)
    if [ "$state" = ok ]; then
      note ok codexbar "$provider" "$detail"
    else
      # codexbar talking to the provider is the only check that proves a token
      # is really alive, so this is a failure rather than a warning.
      #
      # But codexbar keeps its own credentials, separate from the proxy's:
      # re-authenticating cliproxyapi does not repair codexbar's view and vice
      # versa. When its error names the fix, that instruction wins.
      local hint
      hint=$(printf '%s' "$detail" | sed -n 's/.*[Rr]un `\([^`]*\)`.*/\1/p')
      if [ -n "$hint" ]; then
        note fail codexbar "$provider" "$detail" \
          "$hint   (codexbar's own credential store, separate from the proxy's)"
      else
        note fail codexbar "$provider" "$detail" "$(repair_for "$provider")"
      fi
    fi
  done <<EOF
$summary
EOF
}

# ------------------------------------- 4. configured models vs proxy catalog --
# The failure this catches: a model named in grok's config or in the subagent
# router that the proxy cannot actually serve. It looks fine in every config
# file and only fails at spawn time.
check_configured_models() {
  have_python || return 0
  local catalog
  catalog=$(curl -s -m 10 "$PROXY_URL/v1/models" 2>/dev/null)
  # Without a catalog there is nothing to compare against. Say so rather than
  # returning quietly, which would read as "checked and fine".
  [ -n "$catalog" ] || {
    note warn models "configured models" "not checked: the proxy served no catalog" ""
    return
  }

  local missing
  missing=$(python3 - "$GROK_CONFIG" "$ROUTER_CONFIG" <<PY
import json, re, sys, os
try:
    served = {m["id"] for m in json.loads('''$catalog''').get("data", [])}
except Exception:
    sys.exit()
def models_in(path, pattern):
    if not os.path.exists(path):
        return set()
    text = open(path, encoding="utf-8", errors="replace").read()
    return {m.strip('"') for m in re.findall(pattern, text)}
grok = models_in(sys.argv[1], r'^\[model\.([^\]]+)\]')
router = models_in(sys.argv[2], r'^\[models\.([^\]]+)\]')
for name, group in (("grok-config", grok), ("subagent-router", router)):
    for m in sorted(group - served):
        print(f"{name} {m}")
PY
)
  [ -n "$missing" ] || { note ok models "configured models" "every configured model is served by the proxy"; return; }

  local line where model
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    where=$(echo "$line" | cut -d' ' -f1)
    model=$(echo "$line" | cut -d' ' -f2)
    note warn models "$model" "declared in $where but the proxy does not serve it" \
      "remove it from $where or add it to $CLIPROXY_CONF"
  done <<EOF
$missing
EOF
}

# ------------------------------------------------------------- 5. the fixes --
apply_fixes() {
  local acted=0

  # Only genuinely unattended repairs run here. An OAuth or device-code login
  # needs a human at a browser, so it is reported with its exact command
  # instead of being started in the background where it would hang.
  if echo "$FINDINGS" | grep -q '^fail|proxy|'; then
    if [ -n "$LAUNCHD_LABEL" ]; then
      echo "  restarting $LAUNCHD_LABEL"
      launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1
      acted=1
      # Give it a moment to bind the port and load its plugins.
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        curl -s -m 3 "$PROXY_URL/v1/models" >/dev/null 2>&1 && break
      done
    else
      echo "  cannot restart: no launchd job matching 'cliproxy' is loaded"
    fi
  fi

  [ $acted -eq 1 ] || echo "  nothing to repair unattended"
}

# ---------------------------------------------------------------- reporting --
emit_text() {
  local level area subject detail repair line
  local last_area=""
  echo "provider health — $(hostname -s)"
  echo
  while IFS='|' read -r level area subject detail repair; do
    [ -n "$level" ] || continue
    if [ "$area" != "$last_area" ]; then
      printf '\n  %s\n' "$area"
      last_area="$area"
    fi
    case "$level" in
      ok)   printf '    ok    %-26s %s\n' "$subject" "$detail" ;;
      warn) printf '    WARN  %-26s %s\n' "$subject" "$detail" ;;
      fail) printf '    FAIL  %-26s %s\n' "$subject" "$detail" ;;
    esac
    [ -n "$repair" ] && printf '          %-26s -> %s\n' "" "$repair"
  done <<EOF
$FINDINGS
EOF
  echo
  case $STATUS in
    0) echo "healthy" ;;
    1) echo "degraded — see WARN/FAIL above" ;;
    2) echo "broken — the proxy every model depends on is not serving" ;;
  esac
}

emit_json() {
  have_python || { emit_text; return; }
  python3 - "$(hostname -s)" "$STATUS" <<PY
import json, sys
host, status = sys.argv[1], int(sys.argv[2])
rows = []
for line in '''$FINDINGS'''.strip().splitlines():
    parts = line.split("|")
    if len(parts) < 4:
        continue
    rows.append({
        "level": parts[0], "area": parts[1], "subject": parts[2],
        "detail": parts[3], "repair": parts[4] if len(parts) > 4 else "",
    })
print(json.dumps({"host": host, "status": status, "findings": rows}, indent=2))
PY
}

# ------------------------------------------------------------ 6. the other --
# The script sends itself over stdin, so nothing has to be installed on the far
# side and the two machines can never run different versions of this check.
resolve_remote_alias() {
  [ -n "$REMOTE_ALIAS" ] && { echo "$REMOTE_ALIAS"; return; }
  [ -n "${CONAN_CODE_REMOTE_HOST:-}" ] && { echo "$CONAN_CODE_REMOTE_HOST"; return; }
  # Fall back to the aliases the user's ssh config actually defines.
  awk '/^[Hh]ost / {for (i=2;i<=NF;i++) if ($i !~ /[*?]/) print $i}' \
    "$HOME/.ssh/config" 2>/dev/null | head -1
}

remote_reachable() {
  ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$1" 'exit 0' >/dev/null 2>&1
}

run_remote() {
  local alias="$1"
  if [ -z "$alias" ]; then
    echo "no remote alias: pass one, set CONAN_CODE_REMOTE_HOST, or define a Host in ~/.ssh/config"
    return 1
  fi
  if ! remote_reachable "$alias"; then
    echo "remote '$alias' is not reachable right now — skipping it"
    return 0
  fi
  echo "remote '$alias':"
  echo
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$alias" 'bash -s -- check' < "$0" 2>&1 \
    | sed 's/^/  /'
}

# ------------------------------------------------------- 7. driven logins ---
# Every provider re-auth is an OAuth flow: the binary prints a URL, listens on
# a random localhost callback port, and *also* offers to accept the callback URL
# pasted on stdin. Two consequences shape everything below.
#
# It reads stdin, so a plain background start dies instantly on EOF. Its stdin
# is held open by a FIFO opened read-write, which never signals EOF and never
# blocks the way a write-only open would.
#
# And it must still be running when the browser finishes, or the callback lands
# on a closed port. So `login` returns immediately with the URL, the caller
# drives the browser, and `login-wait` collects the result.

login_state_dir() { echo "${TMPDIR:-/tmp}/provider-health-login-$1"; }

login_start() {
  local provider="$1" flag dir
  [ -n "$provider" ] || { echo "usage: login <provider>"; return 2; }
  flag=$(login_flag_for "$provider")
  [ -n "$flag" ] || { echo "no login flow known for '$provider'"; return 2; }
  [ -n "$CLIPROXY_BIN" ] || { echo "cliproxyapi is not installed here"; return 2; }

  dir=$(login_state_dir "$provider")
  login_cancel "$provider" >/dev/null 2>&1
  rm -rf "$dir"; mkdir -p "$dir" || return 2
  mkfifo "$dir/stdin" || return 2

  # 3<> keeps a reader and a writer on the FIFO for the life of this shell, so
  # the child never sees EOF even though nothing has written to it yet.
  exec 3<>"$dir/stdin"
  nohup "$CLIPROXY_BIN" "$flag" <"$dir/stdin" >"$dir/log" 2>&1 &
  echo $! >"$dir/pid"

  local i url
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    url=$(grep -oE 'https://[^ ]*(oauth|auth|login)[^ ]*' "$dir/log" 2>/dev/null | head -1)
    [ -n "$url" ] && break
  done

  if [ -z "$url" ]; then
    echo "no authentication URL appeared within 15s; the log is at $dir/log"
    return 1
  fi

  echo "provider:  $provider"
  echo "account:   ${PROVIDER_HEALTH_GOOGLE_ACCOUNT:-jose.attento@gmail.com}"
  # Providers disagree on the callback host: gemini uses 127.0.0.1, antigravity
  # uses localhost. Accept either so the reported port is never blank.
  echo "callback:  $(echo "$url" | sed -n 's/.*\(127\.0\.0\.1\|localhost\)%3A\([0-9]*\).*/\1:\2/p')"
  echo "url:       $url"
  echo
  echo "now drive the browser to that url, then run: login-wait $provider"
}

login_wait() {
  local provider="$1" seconds="${2:-180}" dir pid i
  dir=$(login_state_dir "$provider")
  [ -f "$dir/pid" ] || { echo "no login in progress for '$provider'"; return 2; }
  pid=$(cat "$dir/pid")

  i=0
  while [ "$i" -lt "$seconds" ]; do
    if ! ps -p "$pid" >/dev/null 2>&1; then
      # Providers word this differently ("Authentication successful." vs
      # "Antigravity authentication successful!"), so match the shape rather
      # than one provider's exact sentence.
      if grep -qiE 'authentication (successful|saved to)' "$dir/log" 2>/dev/null; then
        echo "ok: $(grep -io 'authentication saved to .*' "$dir/log" | head -1)"
        rm -rf "$dir"
        return 0
      fi
      echo "login exited without succeeding; last lines:"
      grep -viE 'plugin|pluginhost|^$' "$dir/log" 2>/dev/null | tail -5
      rm -rf "$dir"
      return 1
    fi
    sleep 2
    i=$((i + 2))
  done
  echo "still waiting after ${seconds}s — the browser flow is not finished."
  echo "if the browser reached a 127.0.0.1 page that refused to connect, the"
  echo "callback listener is gone; recover with:"
  echo "  login-paste $provider '<the full 127.0.0.1 url from the address bar>'"
  return 1
}

# The paste path is the recovery route when the callback cannot be delivered:
# the authorization code is in the browser's address bar even when the page
# itself failed to load.
login_paste() {
  local provider="$1" url="$2" dir
  dir=$(login_state_dir "$provider")
  [ -p "$dir/stdin" ] || { echo "no login in progress for '$provider'"; return 2; }
  [ -n "$url" ] || { echo "usage: login-paste <provider> <callback-url>"; return 2; }
  printf '%s\n' "$url" >"$dir/stdin"
  login_wait "$provider" 30
}

login_cancel() {
  local provider="$1" dir
  dir=$(login_state_dir "$provider")
  [ -f "$dir/pid" ] && kill "$(cat "$dir/pid")" 2>/dev/null
  rm -rf "$dir"
  echo "cancelled any login in progress for '$provider'"
}

# --------------------------------------------------------------------- run --
# A credential file is a claim; codexbar talking to the provider is evidence.
# When they disagree the file is the one that is wrong, and that combination is
# the most misleading state possible: everything local looks fine while calls
# fail. Name it explicitly so nobody trusts the expiry date.
check_contradictions() {
  local line level area subject detail canon dead
  dead=""
  while IFS='|' read -r level area subject detail _; do
    [ "$area" = codexbar ] || continue
    [ "$level" = fail ] || continue
    dead="$dead $(canonical_provider "$subject")"
  done <<EOF
$FINDINGS
EOF
  [ -n "$dead" ] || return 0

  # One provider can own several credential files, so report the provider once
  # rather than once per file.
  local seen=""
  while IFS='|' read -r level area subject detail _; do
    [ "$area" = credentials ] || continue
    [ "$level" = ok ] || continue
    canon=$(canonical_provider "$(echo "$subject" | cut -d/ -f1)")
    case " $seen " in *" $canon "*) continue ;; esac
    case " $dead " in
      *" $canon "*)
        seen="$seen $canon"
        note fail contradictions "$canon" \
          "the proxy credential reads healthy but codexbar's provider check rejects it — the two keep separate credential stores" \
          "$(repair_for "$canon")"
        ;;
    esac
  done <<EOF
$FINDINGS
EOF
}

run_all_checks() {
  FINDINGS=""; STATUS=0
  check_proxy
  check_credentials
  check_codexbar
  check_configured_models
  check_contradictions
}

case "$CMD" in
  login)        login_start  "$LOGIN_PROVIDER"; exit $? ;;
  login-wait)   login_wait   "$LOGIN_PROVIDER" "${LOGIN_ARG:-180}"; exit $? ;;
  login-paste)  login_paste  "$LOGIN_PROVIDER" "$LOGIN_ARG"; exit $? ;;
  login-cancel) login_cancel "$LOGIN_PROVIDER"; exit $? ;;
  remote)
    run_remote "$(resolve_remote_alias)"
    exit $?
    ;;
  fix)
    run_all_checks
    echo "repairing:"
    apply_fixes
    echo
    run_all_checks
    [ $JSON -eq 1 ] && emit_json || emit_text
    ;;
  check)
    run_all_checks
    [ $JSON -eq 1 ] && emit_json || emit_text
    if [ $WITH_REMOTE -eq 1 ]; then
      echo
      run_remote "$(resolve_remote_alias)"
    fi
    ;;
esac

exit $STATUS
