# Hook Relay Spike Results

Date: 2026-08-06

Status: **PASS.** The relay, real Grok hook delivery, cancellation fallback,
abrupt-root fallback, and process-group detachment were validated on the target
machine.

## Implemented contract

- `coinor-hook-relay` reads the complete stdin payload before doing any work.
- Invalid JSON, missing socket configuration, fork failure, connection failure,
  and write failure all return success to Grok.
- The relay forks through a two-line POSIX C shim because Swift 6 marks the
  Darwin `fork()` overlay unavailable.
- The child calls `setsid()`, closes standard descriptors, and performs the
  socket work while the original process exits with status 0.
- Each connection carries one raw JSON payload framed by a four-byte unsigned
  big-endian payload length.
- `COINOR_HOOK_SOCKET` selects the Unix socket.
- `COINOR_HOOK_TIMEOUT_MS` optionally overrides the 150 ms child-side timeout
  and is clamped to 1...2000 ms.
- The synthetic pane state is idempotent by child session ID. Terminal child
  IDs are tombstoned so delayed starts cannot resurrect panes.

## Automated validation

Command:

```sh
Spikes/HookSpike/run-tests.sh
```

The script performs:

```sh
swift build --configuration release --package-path Tools/CoinorHookRelay
swift test --package-path Tools/CoinorHookRelay
COINOR_HOOK_RELAY_EXECUTABLE=<release-relay-path> \
  swift test --package-path Spikes/HookSpike
```

Final result:

```text
Build complete! (0.14s)
Test run with 4 tests in 0 suites passed after 0.001 seconds.
Test run with 20 tests in 1 suite passed after 0.619 seconds.
```

The 20 harness tests cover:

- decoding `SessionStart`, `SubagentStart`, `SubagentStop`, and `SessionEnd`
- exact payload delivery through the real relay executable and Unix listener
- all four registered events driving one listener state in sequence
- duplicate start and duplicate stop idempotency
- stop-before-start tombstones
- ignoring the reserved `observe` stop phase so it cannot close a live pane
- nested-start-before-parent buffering
- immediate-parent to ultimate-root mapping for nested children
- flat start ordering
- parent-stop and child-`SessionEnd` subtree cleanup
- root-`SessionEnd` and synthetic root-process-death cleanup
- real `events.jsonl` cancellation-shape fallback
- real `updates.jsonl` terminal retry-failure fallback
- ignoring non-terminal retrying updates
- preserving children when only the root turn is cancelled
- events from unactivated roots remaining inert
- success with no listener, no socket configuration, or invalid JSON

Measured relay-process results from the final run:

```text
payload delivered to listener: 0.013s
four-event lifecycle sequence: 0.028s
no listener: 0.008s, exit 0
no socket configuration: 0.007s, exit 0
```

An earlier cold `Foundation.Process` launch took 0.467 seconds; subsequent
isolated runs were in the range above. Direct Release invocation outside the
test runner was below `time(1)`'s 0.01-second resolution on five consecutive
runs:

```text
run 1: real 0.00 user 0.00 sys 0.00
run 2: real 0.00 user 0.00 sys 0.00
run 3: real 0.00 user 0.00 sys 0.00
run 4: real 0.00 user 0.00 sys 0.00
run 5: real 0.00 user 0.00 sys 0.00
```

Release harness build:

```sh
swift build --configuration release --package-path Spikes/HookSpike
```

Result:

```text
Build complete! (0.13s)
```

Shell validation:

```sh
sh -n Spikes/HookSpike/run-tests.sh
```

Result: exit 0 with no output.

## Release-process smoke test

The Release harness listened on a temporary socket while the Release relay
sent these fixtures in order:

```text
SessionStart -> SubagentStart -> SubagentStop -> SessionEnd
```

Final snapshot:

```json
{
  "activeRootSessionIDs": [],
  "panes": [],
  "pendingChildSessionIDs": [],
  "terminalSessionIDs": [
    "00000000-0000-7000-8000-000000000001",
    "00000000-0000-7000-8000-000000000002"
  ]
}
```

## Real Grok validation

The Coinor-owned registration was installed idempotently as:

```text
~/.grok/hooks/coinor.json
~/.grok/hooks/coinor-hook-relay
```

`scripts/hooks/install.sh` refuses to overwrite a registration without the
Coinor ownership marker. `scripts/hooks/verify.sh` validates the four event
registrations, executable path, and Application Support socket.

A real root session with one native subagent produced:

```text
SessionStart(root)
SubagentStart(sessionId=root, subagentId=child)
SubagentStop(sessionId=child, subagentId=child, phase=gate)
SessionEnd(child)
SessionEnd(root)
```

The validated IDs were:

```text
root:  dfa2aa74-74d0-460c-bf28-04330aaec021
child: 019fd94f-4aac-7f02-9083-9f9b5c932dff
```

The final listener snapshot had no active roots, panes, or pending children.
This also established an important current-Grok contract: `SubagentStart`
carries the immediate parent in `sessionId`, while `SubagentStop` carries the
child in both `sessionId` and `subagentId`.

An interactive TUI cancellation used the real `Esc` cancellation flow while a
child was running. The child session
`019fd955-a76c-7e83-8d5f-3e116798c9c1` persisted:

```json
{"type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort"}
```

The focused parser test
`cancellationFixtureClosesChildWithoutSubagentStop` validates that this exact
durable shape closes the pane without relying on a stop hook.

A separate real session was killed with `SIGKILL` immediately after its target
`SubagentStart`. Its only target lifecycle hooks were:

```text
SessionStart(root)
SubagentStart(root -> child)
```

The root PID was dead, with no terminal hook available. The focused
`rootDeathClosesEveryDescendantUsingUltimateRootIdentity` test then validated
the liveness fallback used by Coinor.

Finally, a 15 MiB framed payload forced the detached relay child to remain
alive under socket backpressure. Killing the original hook process group left
the child alive with its own PID/PGID, and it delivered all 15,728,904 payload
bytes after the listener resumed:

```text
PASS: detached child survived killpg and delivered the complete frame
```

No file in `grok-build` or `~/.grok/config.toml` was modified.
