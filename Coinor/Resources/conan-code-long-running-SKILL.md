---
name: conan-code-long-running
description: Create and control visible Conan Code terminal tabs for long-running or interactive commands such as development servers, watchers, tail -f, REPLs, and services that need repeated log reads or input. Use automatically for persistent commands inside Conan Code. Do not use for ordinary finite builds, tests, migrations, or one-shot commands unless the user explicitly asks for a tab.
allowed-tools: run_terminal_command
user-invocable: true
compatibility: Requires Conan Code. The commands fail outside Conan Code.
---

# Conan Code long-running terminals

Use `sh ~/.grok/skills/conan-code-long-running/terminal.sh`. Never replace this
workflow with Grok background tasks when it reports that it is outside Conan
Code.

## Create

Choose a fresh UUID literal yourself. Put that exact literal in both places;
do not generate it in the shell or hide it behind a variable:

```bash
CONAN_CODE_REQUEST_ID=<uuid-literal> \
  sh ~/.grok/skills/conan-code-long-running/terminal.sh create \
  --request-id <uuid-literal> --title '<short tab title>' --cwd '<directory>'
```

Keep the returned `tabID` and `capability`. They are opaque and control only
the tab created by this agent. Creation is in the background and never changes
the user's selected tab.

Poll `status` until the state is `idle` before the first managed command:

```bash
sh ~/.grok/skills/conan-code-long-running/terminal.sh status \
  --tab '<tabID>' --capability '<capability>'
```

## Operate

- Start one command: `execute --tab ... --capability ... --command '<command>'`
- Read logs: `read --tab ... --capability ...` and pass the returned cursor to
  later reads with `--cursor`.
- Send text: `write --tab ... --capability ... --text '<text>'`
- Send a key: `key --tab ... --capability ... --key enter|escape|up|down|left|right`
- Interrupt the foreground job: `interrupt --tab ... --capability ...`
- Inspect state: `status --tab ... --capability ...`
- Stop and remove the tab: `close --tab ... --capability ...`

The shell is reusable. Sequential managed commands preserve `cd`, exports,
functions, and other shell state. Only one managed command may run at a time,
but text and key input remain available for interactive programs.

## Cleanup

Before finishing the task, interrupt any running command and close every tab
you created unless the user explicitly asked to leave a service running. If
the user closes a tab manually, report `tab_gone` and do not recreate it.
