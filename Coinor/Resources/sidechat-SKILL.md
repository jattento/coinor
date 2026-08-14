---
name: sidechat
description: Fork the current Grok session into a new Conan Code tab, so the branch runs as its own agent next door instead of inside this pager.
argument-hint: "[tab name]"
allowed-tools: run_terminal_command
disable-model-invocation: true
compatibility: Requires Conan Code, jq, uuidgen
---

# sidechat

Run the script once. Choose a fresh UUID literal yourself and put it in the
command line as `CONAN_CODE_REQUEST_ID`; everything after the script path is the
new tab's name, passed through verbatim. With no arguments the tab is named
`sidechat`.

```bash
CONAN_CODE_REQUEST_ID=<uuid-literal> sh ~/.grok/skills/sidechat/sidechat.sh <arguments>
```

The literal must be visible in this exact command text: Conan Code authorizes
tab creation by matching the request ID it saw in the agent's own terminal
command against the one the control client sends. A UUID generated inside the
shell, or hidden behind a variable, was never observed and is always rejected.

Report the script's output — tab name, tab ID, and fork session ID — and nothing
else. Do not inspect the new tab, prompt the fork, or continue the user's task
in it: the fork is a separate agent the user drives from its own tab.

If the script fails, print its stderr and stop. The likely causes are running
outside Conan Code, a missing or reused `CONAN_CODE_REQUEST_ID`, or a stale
`~/.grok/active_sessions.json` entry after a crash.

## Why not `/fork`

Grok's built-in `/fork` branches into a peer session inside the same pager
process (visible in `/dashboard`), and no hook event fires for it — so there is
nothing to intercept and relocate. This forks from the outside instead:
`grok --resume <session> --fork-session --session-id <new-uuid>` in a new Conan
Code tab, which is a real history copy under a new ID with exactly one live
client on it.
