# Remote hosts

## Purpose

Conan Code shows projects and conversations from other Macs in the same window
as local ones. A remote project's conversations, subagents, IDE tools, and
shells execute on the remote computer; only the terminal surface and the
sidebar are local.

The motivation is desk consolidation: work on every project from one computer
without physically switching machines.

## Transport

Conan Code is not a server and does not listen on the network. Every remote
operation is an ordinary `ssh` invocation of the same command the local path
already runs.

```text
local root pane   grok --leader-socket <local> --leader --cwd X --resume ID
remote root pane  ssh -t <host> 'cd X && exec grok --leader-socket <remote> --leader --resume ID'

local control     grok --leader-socket <local> agent --leader stdio
remote control    ssh <host> 'exec grok --leader-socket <remote> agent --leader stdio'
```

The ACP control plane speaks JSON-RPC over the process's standard streams and
requires no TTY, so an SSH channel carries it unchanged. Interactive panes
allocate a TTY with `-t`.

Authentication belongs entirely to OpenSSH. Conan Code stores a host alias and
nothing else: no user, port, key path, passphrase, or credential of any kind.

### Connection multiplexing

All channels for one host share a Conan Code-owned master connection:

```text
-o ControlMaster=auto
-o ControlPath=<Application Support>/Coinor/ssh/<alias>.sock
-o ControlPersist=300
-o ServerAliveInterval=15
-o ServerAliveCountMax=3
```

One conversation can open many channels at once: root, every subagent, Fresh,
Lazygit, each shell tab, plus the host's control client. `sshd` defaults to
`MaxSessions 10` per connection, so the host health check reports the remote
value and recommends raising it. Conan Code does not modify the remote host's
configuration.

Non-interactive commands (catalog, Git, discovery) add `-o BatchMode=yes` so a
credential prompt fails fast instead of hanging an invisible channel.

## Remote runtime

Each remote host runs a dedicated Grok leader on a stable socket:

```text
<remote Application Support>/Coinor/grok-leader-remote.sock
```

This is deliberately not the socket the remote computer's own Conan Code uses.
That installation keeps its private leader and its start-up recycling
untouched, so opening or quitting Conan Code on the remote machine can never
kill panes owned by this one.

The remote leader is started on demand through SSH when its `flock` is free and
is otherwise reused. It is never stopped implicitly: quitting Conan Code leaves
remote agents running, and reconnecting reattaches to live panes. `Stop remote
runtime`, in the host's detail view, is the only way to end it and asks for
destructive confirmation.

This intentionally revises the `architecture.md` non-goal that forbade a
runtime surviving application exit. The revision is scoped to remote hosts;
the local runtime keeps its existing lifecycle.

Sitting at the remote computer, its own Conan Code lists these conversations
normally, because Grok persists them there, and can resume any of them. It does
not share the live pane: live attachment is available from whichever machine
holds the client.

## Host registration

`Add remote computer` lists the `Host` entries of `~/.ssh/config`. Selecting one
runs the same compatibility contract the local path runs at start-up:

1. reach the host over SSH
2. resolve the Grok executable and record `grok --version`
3. require the remote fork base version to equal the local one, warning when
   only the overlay build differs
4. open the ACP control connection
5. start or adopt the remote leader
6. report the remote `MaxSessions` value

Any failure produces one actionable English diagnostic and no partially
registered host. The base version must match exactly, because Conan Code's ACP
extension methods are contracts of that fork version; a differing overlay build
connects and shows a non-blocking warning naming both versions.

## Projects and identity

A remote project is resolved with exactly the same Git rules as a local one,
executed remotely: `git rev-parse --git-common-dir` and
`git worktree list --porcelain` run over SSH in the candidate directory.

Every identity gains a host component. `ProjectIdentity` becomes
`(host, common directory)` and conversation references become
`(host, Grok session ID)`. Remote paths are never normalized through the local
file system: symlink resolution and existence checks belong to the machine that
owns the path.

Conan Code opens one control client per registered host and merges their
catalogs. Everything Grok persisted on a remote host appears, including
conversations started from its terminal, grouped by its repositories.

Organization metadata stays local to each installation, as ADR-0008 already
requires. Two machines can show the same project with different names, icons,
pins, and order; nothing is synchronized.

## Choosing a remote directory

`NSOpenPanel` cannot browse another machine, so adding a remote project uses a
Conan Code-owned picker:

1. a catalog of real repositories, built from the Git roots already present in
   the host's Grok catalog plus a bounded remote scan for `.git` directories
2. a fuzzy filter over that catalog
3. a `Browse…` fallback that lists remote directories over SSH and marks which
   ones are repositories

No path is ever typed by hand.

## Conversation behavior

Remote conversations behave like local ones:

- the root pane, subagent panes, IDE tab, and shell tabs all execute remotely
- subagent lifecycle arrives on the host's ACP stream and each pane opens its
  own SSH channel
- `In New Worktree` runs the fetch, default-branch resolution, and worktree
  creation on the remote host, using that host's Git credentials
- attention state and notifications work unchanged, because they are ACP facts

Agent-managed terminal tabs (ADR-0013) are local-only. A remote Grok agent
inherits neither the control socket path nor the instance token, so the skill
fails closed exactly as designed and the agent uses its ordinary terminal tool.
A reverse Unix-socket forward could lift this later; it is not in this design.

## Disconnection

A dropped SSH connection does not end the work: the Grok leader keeps the
session alive on the remote host.

When a pane's `ssh` exits with a network status, Conan Code relaunches the same
command in the same surface with bounded backoff and shows a `Reconnecting`
banner, reusing the retry mechanism that already exists for subagent resume.
Exhausting the budget leaves a `Disconnected` banner with a manual
`Reconnect` action. A clean exit is never retried, and a genuine Grok failure
is shown rather than hidden behind a reconnect loop.

While a host is unreachable, its projects stay in the sidebar with a red host
badge and their conversations remain listed.

## Presentation

Remote projects sit in the same flat `Projects` list as local ones with a small
host badge on the project row. There is no per-computer section: the sidebar's
flat structure is a standing product rule.

## Hiding remote projects

The sidebar's `Remote Computers` menu can hide every remote project at once.
This changes presentation only: registered computers, their runtimes, and any
work running on them are untouched, and the choice is stored with the rest of
Conan Code's local organization metadata.

## Security

- no credential, key path, user name, or port is persisted by Conan Code
- no network listener is added to the application
- host aliases come from `~/.ssh/config`; `known_hosts` verification is
  OpenSSH's
- remote command construction quotes every interpolated value; no user-supplied
  string is concatenated into a remote shell command unquoted
