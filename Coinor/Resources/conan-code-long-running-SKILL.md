---
name: conan-code-long-running
description: Automatically create and control visible Conan Code terminal tabs, without asking first, whenever the user requests a development server, database, container stack, watcher, tail -f, REPL, daemon, service, or other long-running or interactive command. Use even when the user does not mention tabs or this skill. Do not use for ordinary finite builds, tests, migrations, or one-shot commands unless the user explicitly asks for a tab. Clean up every tab before the final response unless the user explicitly says to leave it running.
allowed-tools: run_terminal_command
user-invocable: true
compatibility: Requires Conan Code. The commands fail outside Conan Code.
---

# Conan Code long-running terminals

Use `sh ~/.grok/skills/conan-code-long-running/terminal.sh`. Never replace this
workflow with Grok background tasks when it reports that it is outside Conan
Code.

## Mandatory automatic behavior

- Use this skill automatically for service-like work. Examples include starting
  an application server, database, Docker Compose stack, local emulator,
  watcher, streaming log, REPL, daemon, or any command expected to keep
  running while other work continues.
- Do not ask the user whether to open a tab, and do not wait for the user to
  mention tabs or this skill. Creating a managed tab is an implementation
  detail.
- Use one tab per independently controlled process, or one tab for a stack
  managed by one foreground command. Run finite setup, build, test, and
  migration commands through the ordinary terminal tool.
- After starting a service, inspect its logs or status and perform the
  requested readiness or behavior check while it remains in the managed tab.
- A request to start, launch, run, or bring up a service for the task does not
  by itself mean to leave it running after the task.

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

Before sending the final response, interrupt every command still running and
close every managed tab you created unless the user explicitly asked to leave
a specific service running. Poll status after the interrupt when needed, then
close the tab even when the command or wider task failed. Do not treat an
ordinary request to start a server, database, stack, watcher, or service as a
request to keep it running.

If the user explicitly asks to leave a service running, keep only the named
tab or service and report its status. If the user closes a tab manually,
report `tab_gone` and do not recreate it.
