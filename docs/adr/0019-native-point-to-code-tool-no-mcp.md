---
status: accepted
---

# Add a native `point_to_code` tool instead of an MCP bridge

Grok had no way to show the user a specific range of code together with an
explanation; it could only describe a file and line number in prose, leaving
the user to open and scroll to the right place themselves.

An MCP server bridging Coinor and Grok was considered and rejected. Running
and maintaining a separate MCP server process adds resource and operational
overhead disproportionate to a single narrow tool, and the user already
maintains a personal fork of the Grok CLI, `github.com/jattento/grok-build`
(installed at `~/bin/grok`), specifically so changes like this one can ship as
a real native tool instead of a bolted-on integration.

`point_to_code` is a native tool added to that fork. It is listed to the
model only when three environment variables — `CONAN_CODE_CONTROL_SOCKET`,
`CONAN_CODE_CONTROL_TOKEN`, and `CONAN_CODE_SESSION_ID` — are present on the
root Grok process, which Coinor injects for local conversations only. When
called, it opens a raw connection directly to Coinor's existing
terminal-control Unix socket (ADR 0013) and hand-encodes a `point-to-code`
request matching `TerminalControlContract`'s exact wire shape, since the two
repositories share no compiled contract. Coinor's `AppCoordinator` queues the
request on the owning `ConversationRuntime`.

A second new terminal-control method, `tour-wait`, is polled every two
seconds by a new Fresh editor plugin, `conan-code-tour`, running inside the
IDE tab's `fresh .` process. Coinor installs the plugin verbatim into
`~/.config/fresh/plugins/` (`FreshPluginInstaller`, mirroring
`GrokSkillInstaller`'s atomic-write behavior) so it autoloads with no
`init.ts` edit required. The plugin runs `coinorctl tour-wait` as a
subprocess, reading the bundled client path and conversation ID Coinor
injects into the IDE tab's environment, and when a request is pending, writes
a one-step `.fresh-tour.json` manifest and opens it through Fresh's own
bundled `code-tour` plugin API, highlighting the range and showing the
comment.

This end-to-end path was validated live end to end, inside a real running
Coinor instance: a real conversation's root Grok process called
`point_to_code`, and the IDE tab's `fresh .` opened `example.swift` with
lines 4–8 highlighted and the model's comment shown in a step navigator,
matching the original mockup this feature was built from. A negative-control
run without the three environment variables confirmed the tool is not listed
at all.

One interaction nuance surfaced during that verification: Fresh's own
`code-tour` plugin does not replace an already-open tour. If a second
`point_to_code` request arrives while a previous tour is still open, nothing
visibly changes until the user finishes the current tour (`q`); the next
poll then opens the new one correctly. This is a known, narrow follow-up —
not a broken pipeline — and a natural target for the multi-step tours phase
below, which will not need to open a fresh tour per call at all.

This is phase 1 of a three-phase plan. Multi-step tours and user-left
comments Grok can read back are not yet built.

Coupling the wire shape across two repositories that share no compiled
contract is a documented risk: a change to `TerminalControlContract` in
Coinor is not caught by the compiler in grok-build and can silently break
`point_to_code` until it is manually re-verified against both repositories.
Like managed terminal tabs (ADR 0013) and the Browser Mirror tab (ADR 0016),
this is local-only: Coinor never injects the control-socket environment
variables for remote-host conversations, so a remote agent has no
`point_to_code` tool at all.
