---
name: provider-health
description: Verify that every configured AI provider actually works, and repair the ones that do not. Checks the CLIProxyAPI proxy every model routes through, the expiry of each provider credential, live quota from the codexbar CLI, and whether every model named in Grok's config and in the subagent router is really served. Use whenever a model call fails for a reason that smells like the provider rather than the request, when a subagent falls back to another model unexpectedly, when quota or credentials look stale, or when the user asks to check, verify, fix, or re-authenticate providers. Also use before starting long unattended work that depends on several providers. Runs on both the personal and the work Mac, and checks the other machine too when it is reachable.
allowed-tools: run_terminal_command
user-invocable: true
compatibility: Requires cliproxyapi and codexbar on the machine being checked. Reports what is missing instead of failing when one of them is absent.
---

# Provider health

One script does everything:

```sh
sh ~/.grok/skills/provider-health/provider-health.sh <command>
```

## Commands

| Command | What it does |
| --- | --- |
| `check` | Full report. This is the default. |
| `check --json` | Same report as structured JSON, for when you need to reason over it. |
| `check --with-remote [alias]` | Local report, then the same report from the other Mac when it is reachable. |
| `fix` | Applies the repairs that need no human, then re-runs the check. |
| `remote <alias>` | Runs `check` on the other Mac only. |

Exit code: `0` healthy, `1` degraded, `2` broken.

## What it checks

1. **The proxy.** CLIProxyAPI is what every configured model routes through, so it is checked first and a failure here is reported as `broken`: nothing else can work. Confirms something is listening on the configured port and that `/v1/models` returns a catalog.
2. **Credentials.** Every file in the proxy's auth directory, reported as provider, account and expiry. Expired is a failure, expiring today is a warning. A credential with no expiry field is a refresh token or API key — nothing local can prove it still works, so it is listed as informational and the live proof comes from the next two checks.
3. **Live quota.** `codexbar usage --format json`, one row per provider with either its usage percentages or the exact error it returned.
4. **Configured models.** Every `[model.*]` in `~/.grok/config.toml` and every `[models.*]` in `~/.grok/subagent-router.toml`, checked against what the proxy actually serves. This catches the quiet failure where a model is named in every config file but no provider can serve it, so it only breaks at spawn time.

## Repairing

Run `fix` first. It handles what can be done unattended — currently restarting the proxy when it is down or not serving a catalog — and then re-checks.

**It deliberately does not run login flows.** Every provider re-authentication is an OAuth or device-code flow that needs a human at a browser, so the report prints the exact command instead:

```
FAIL  antigravity/...  expired-181d-ago-on-2026-02-16
                       -> /opt/homebrew/bin/cliproxyapi -antigravity-login
```

Give the user those commands to run. Do not start one in the background: it will hang waiting for input that never comes.

## The other Mac

`check --with-remote` sends this script over SSH and runs it there, so nothing has to be installed on the far side and both machines can never run different versions of the check.

The alias is resolved in this order: the one passed on the command line, then `$CONAN_CODE_REMOTE_HOST`, then the first concrete `Host` in `~/.ssh/config`. If the other Mac is not reachable, the script says so and moves on — an unreachable machine is not a failure.

A remote report can only ever be a report. Credential repair there needs a browser on that machine, so relay the commands to the user rather than trying to drive them.

## Reading the report

Work top down. The sections are ordered by how much depends on them, so a proxy failure explains everything below it and should be fixed before anything else is interpreted. A credential that is expired but whose provider still shows live quota in `codexbar` usually means that provider has a second working account.

## Secrets

The script reads credential files to report their type and expiry and never prints, copies, or transmits a secret value. Keep it that way: do not add anything that echoes a token, and do not paste credential file contents into the conversation.
