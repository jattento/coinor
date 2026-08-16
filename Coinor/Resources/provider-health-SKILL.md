---
name: provider-health
description: Verify that every configured AI provider actually works, and repair the ones that do not, including driving the Google OAuth flow in the browser to renew an expired credential. Checks the CLIProxyAPI proxy every model routes through, the expiry of each provider credential, live quota from the codexbar CLI, and whether every model named in Grok's config and in the subagent router is really served. Use whenever a model call fails for a reason that smells like the provider rather than the request, when a subagent falls back to another model unexpectedly, when quota or credentials look stale, or when the user asks to check, verify, fix, or re-authenticate providers. Also use before starting long unattended work that depends on several providers. Runs on both the personal and the work Mac, and checks the other machine too when it is reachable.
allowed-tools: run_terminal_command, chrome-devtools
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
| `login <provider>` | Starts an OAuth re-authentication and prints the URL to drive. Returns immediately. |
| `login-wait <provider> [s]` | Waits for that login to finish and reports the result. |
| `login-paste <provider> <url>` | Recovery: hands the callback URL to a login whose listener already closed. |
| `login-cancel <provider>` | Abandons a login in progress. |
| `remote <alias>` | Runs `check` on the other Mac only. |

Exit code: `0` healthy, `1` degraded, `2` broken.

## What it checks

1. **The proxy.** CLIProxyAPI is what every configured model routes through, so it is checked first and a failure here is reported as `broken`: nothing else can work. Confirms something is listening on the configured port and that `/v1/models` returns a catalog.
2. **Credentials.** Every file in the proxy's auth directory, reported as provider, account and expiry. Expired is a failure, expiring today is a warning. A credential with no expiry field is a refresh token or API key — nothing local can prove it still works, so it is listed as informational and the live proof comes from the next two checks.
3. **Live quota.** `codexbar usage --format json`, one row per provider with either its usage percentages or the exact error it returned.
4. **Configured models.** Every `[model.*]` in `~/.grok/config.toml` and every `[models.*]` in `~/.grok/subagent-router.toml`, checked against what the proxy actually serves. This catches the quiet failure where a model is named in every config file but no provider can serve it, so it only breaks at spawn time.

## Repairing

**Every `->` line in the report is a command to run, not advice to relay.** The report already resolved which repair applies to which provider, so execute it rather than reasoning about it again. Only stop and ask the user when the repair touches an account that is not theirs (see the note on other Google identities below).

Run `fix` first for the unattended repairs — currently restarting the proxy when it is down or not serving a catalog. Then re-check, and work the remaining `->` lines top down.

## What each section proves

The sections are not equally trustworthy, and the difference matters:

- A **credential file** is a *claim*. Its expiry date says when the token was minted to last, not whether it still works. A token revoked server-side leaves the file looking perfectly healthy.
- **codexbar** talking to the provider is *evidence*. It is the only check here that proves a token is really alive, which is why a codexbar error is a failure rather than a warning.
- The **contradictions** section fires when the two disagree: the file reads healthy and the provider still rejects the token. That is the most misleading state possible, because everything local looks fine while calls fail. Trust the provider, not the file.

A credential that expired less than a day ago is reported as healthy on purpose: these are short-lived access tokens and their refresh token renews them on the next call. Only staleness measured in days means something is actually broken.

## Renewing an expired credential

Drive this yourself with the browser tools. The browser already holds the Google session, so the flow is choose-account plus confirm; no password is ever typed and none should be.

```sh
sh ~/.grok/skills/provider-health/provider-health.sh login <provider>
```

It prints the authentication URL and returns immediately, leaving the login process running and its callback port open.

1. Navigate the browser to the printed URL.
2. **Take an accessibility snapshot and click the account whose text contains `jose.attento@gmail.com`.** There are several Google accounts signed in and the others belong to different organisations, so match the email exactly — never pick by position. Use the snapshot `uid`, not a JavaScript `.click()`: a synthetic click does not advance Google's account chooser.
3. Google then shows a confirmation screen titled about having downloaded the app from Google. Click its **Iniciar sesión** / **Sign in** button. Verify the email shown on that screen is the right one before clicking.
4. Collect the result:

```sh
sh ~/.grok/skills/provider-health/provider-health.sh login-wait <provider>
```

Success looks like `ok: authentication saved to /Users/.../<provider>-....json`.

Then re-run `check` and confirm the credential moved out of `FAIL`. A freshly minted token often reads `expires-today`, which is normal for a short-lived credential that refreshes itself.

### When it goes wrong

- **The browser lands on a `127.0.0.1` or `localhost` page that refused to connect.** The login process died before the callback arrived, usually because too much time passed. The authorisation code is still in the address bar, so recover without redoing the flow:
  ```sh
  sh ~/.grok/skills/provider-health/provider-health.sh login-paste <provider> '<full url from the address bar>'
  ```
- **Starting over.** `login-cancel <provider>` kills anything in flight; `login` also clears a previous attempt on its own.
- **Do not run `cliproxyapi -<provider>-login` directly.** It reads stdin, so it dies instantly on EOF when started in the background, and it hangs forever when started in the foreground. The `login` command exists because it holds stdin open for exactly this reason.

A different Google identity is a different credential: entries such as `gemini-cli/google-one-*` belong to other accounts, so signing in as `jose.attento@gmail.com` will not clear them. Ask the user before touching those.

Override the expected account with `PROVIDER_HEALTH_GOOGLE_ACCOUNT` when working on a machine that uses a different one.

## The other Mac

`check --with-remote` sends this script over SSH and runs it there, so nothing has to be installed on the far side and both machines can never run different versions of the check.

The alias is resolved in this order: the one passed on the command line, then `$CONAN_CODE_REMOTE_HOST`, then the first concrete `Host` in `~/.ssh/config`. If the other Mac is not reachable, the script says so and moves on — an unreachable machine is not a failure.

A remote report can only ever be a report. Credential repair there needs a browser on that machine, so relay the commands to the user rather than trying to drive them.

## Reading the report

Work top down. The sections are ordered by how much depends on them, so a proxy failure explains everything below it and should be fixed before anything else is interpreted. A credential that is expired but whose provider still shows live quota in `codexbar` usually means that provider has a second working account.

## Secrets

The script reads credential files to report their type and expiry and never prints, copies, or transmits a secret value. Keep it that way: do not add anything that echoes a token, and do not paste credential file contents into the conversation.
