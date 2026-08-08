---
status: accepted
---

# Control long-running commands with managed terminal tabs

Conan Code exposes a private terminal-control service for Grok agents that need
long-running or interactive commands. The service listens on a Unix socket in
Conan Code's Application Support directory and accepts requests only from the
current user.

The application bundle includes a native `coinorctl` client and a zsh
bootstrap. Conan Code installs an app-owned Grok skill at
`~/.grok/skills/conan-code-long-running`. The skill is intended for servers,
watchers, streaming logs, REPLs, and other commands that need repeated reads or
input. Finite builds, tests, and migrations continue to use Grok's ordinary
terminal tool unless the user explicitly requests a tab.

The private Grok leader inherits the socket path, client path, and an ephemeral
application-instance token. A `create` request also carries a literal nonce.
Conan Code authorizes that nonce only after observing the matching
`run_terminal_command` invocation and its exact Grok session ID on the native
ACP stream. This keeps creation scoped to Grok sessions running through Conan
Code while allowing any requested working directory. Direct Grok processes
outside Conan Code do not inherit the client environment or appear on Conan
Code's ACP stream, so the skill fails closed.

After creation, the caller receives an opaque tab ID and capability. The
capability is required for every operation and is never persisted. Root agents
and subagents can therefore control only handles returned to them. A tab the
user closes returns `tab_gone`; it is never recreated implicitly.

Each managed tab runs a reusable `/bin/zsh -il` Ghostty surface. The bootstrap
fetches commands out of band, evaluates them in the same shell, and reports
completion and exit status over the control socket. This preserves directory,
environment, aliases, and functions between sequential commands without
parsing visible terminal sentinels. Text, named keys, Ctrl-C, status, and
bounded incremental scrollback reads remain available while a command runs.

Managed tabs appear after persisted shell tabs without changing selection or
stealing focus. They remain mounted while hidden, but their labels, order,
processes, capabilities, and scrollback are transient and are never restored
after application relaunch.

Archiving is an immediate destructive runtime action. If a conversation or
project has a loaded runtime, Conan Code confirms before archiving. After
confirmation it stops root Grok, active subagents, Fresh, Lazygit, ordinary
shell tabs, managed tabs, and their child processes before unloading the
runtime. Inactive items archive without confirmation. Archiving still changes
only Conan Code metadata and never deletes the durable Grok session.
