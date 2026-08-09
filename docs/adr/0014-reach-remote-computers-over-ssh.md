---
status: accepted
---

# Reach remote computers over SSH

Conan Code can register other Macs as remote hosts and run their projects'
conversations, subagents, IDE tools, and shells there while rendering every
terminal surface locally.

Remote execution is plain `ssh` invocation of the commands Conan Code already
runs locally. Conan Code adds no network listener, no daemon, and no protocol
of its own, and it persists no credential, key path, user, or port. Host
aliases come from `~/.ssh/config` and authentication belongs to OpenSSH.

Each remote host runs a dedicated Grok leader on its own stable socket,
separate from the private leader used by that computer's own Conan Code, so the
two installations cannot terminate each other's runtimes. The remote leader is
started on demand, reused, and stopped only by explicit user action. This
revises the previous non-goal that no Conan Code runtime may survive
application exit; the revision is scoped to remote hosts and the local runtime
keeps its existing recycling behavior.

Identity gains a host component: projects are keyed by host and Git common
directory, conversations by host and Grok session ID. Remote paths are never
resolved or validated through the local file system. Organization metadata
remains local to each installation and is never synchronized, consistent with
ADR-0008.

The remote Grok fork's base version must equal the local one, because Conan
Code's ACP extension methods are contracts of that fork version. A differing
overlay build is allowed and reported as a non-blocking warning naming both
versions.

Agent-managed terminal tabs from ADR-0013 remain local-only. A remote agent
inherits neither the control socket nor the instance token, so that skill fails
closed and the agent falls back to Grok's ordinary terminal tool.
