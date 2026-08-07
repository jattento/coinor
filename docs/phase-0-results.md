# Phase 0 results

Date: August 6, 2026

## Decision

**GO.** The embedded Ghostty, shared Grok session, and hook relay spikes pass
their Phase 0 implementability gates. Coinor may proceed to Phase 1 without
modifying Grok, enabling global `use_leader`, or depending on Herdr, Paseo, or
an installed Ghostty application.

No complete product sidebar or application UI was built before all three
integration boundaries had passing evidence.

## Environment and boundaries

The validated host is macOS 26.5.1 on arm64 with Xcode 26.2, Swift 6.2.3, and
the pinned Zig 0.15.2 used only from Coinor's ignored build cache.

The custom Grok binary under test reports:

```text
grok 0.2.117 (29189e7)
```

Boundary verification:

```sh
scripts/phase0/check-boundaries.sh
scripts/hooks/verify.sh
git diff --check
```

Result:

```text
PASS: repository boundaries are intact.
PASS: Coinor hook registration is valid.
```

The SHA-256 of `~/.grok/config.toml` remained:

```text
a33ab461777d94cd9a5d40f2fc1c0323adbd11b2bd5f89a29e228fbe51c77300
```

The initial and final `grok-build` status for this gate is exactly:

```text
 M overlay/hooks/herdr-subagent-pane.sh
?? CONTEXT.md
?? docs/
?? overlay/tests/fixtures/
?? overlay/tests/model_matrix.py
```

## Ghostty spike

Status: **PASS**

Commands:

```sh
scripts/ghostty/verify.sh
Spikes/GhosttySpike/test.sh
Spikes/GhosttySpike/exercise.sh
Spikes/GhosttySpike/minimal-environment.sh
```

The static artifact was previously produced by the recorded clean build:

```sh
scripts/ghostty/build.sh
```

Evidence:

- Ghostty tag `v1.3.1`, commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- static arm64 XCFramework and matching resources/terminfo
- Sentry symbols absent and manifest hashes verified
- recursive user configuration loaded with zero diagnostics
- real interactive PTY launched from an absolute command and cwd
- select, copy, paste, scroll, keyboard input, compact/wide resize, URL and
  close callbacks, occlusion, wake notification, and backing-property paths
  exercised
- unsupported window, tab, and split actions suppressed with one visible
  window remaining
- four surface creates matched by four destroys, with no surviving child
  process
- Finder-style minimal environment passed
- no dynamic or embedded dependency on `/Applications/Ghostty.app`

Final runtime summary:

```text
runtime_exercise=passed
surface_create_count=4
surface_destroy_count=4
screenshot_probe=passed
compact_screenshot=732x524
wide_screenshot=1192x844
minimal_environment_launch=passed
installed_ghostty_read_denied_for_config_and_resources=passed
```

Direct screenshots:

- `Spikes/GhosttySpike/.build/ghostty-spike-compact.png`
- `Spikes/GhosttySpike/.build/ghostty-spike-wide.png`

The available host exposed one display at backing scale `1.0`. Coinor exercised
the backing-property transition and wake-notification paths, but did not induce
a physical cross-display Retina transition or put the machine to sleep. These
remain hardware-level validation items for the final application pass, not an
unproven API boundary: scale/display forwarding and wake reconciliation are
implemented and executed.

The optional Xcode Metal Toolchain is required only to rebuild Ghostty from
source. It was removed after the recorded clean build and currently reports
`Status: uninstalled`.

Detailed evidence: `Spikes/GhosttySpike/RESULTS.md`.

## Shared Grok session spike

Status: **PASS**

Commands:

```sh
python3 -m py_compile Spikes/GrokSharedSession/run_spike.py
python3 Spikes/GrokSharedSession/run_spike.py
```

Final root-run evidence:

```text
PASS private leader convergence
PASS client-generated root UUID
PASS ACP replay and live fan-out
PASS exact root TUI resume from unrelated cwd
PASS root driver preservation
PASS native hidden subagent discovery
PASS live hidden child TUI resume from unrelated cwd
PASS inherited child driver preservation
PASS no Herdr or global use_leader dependency
```

The final run launches the hidden-child TUI before waiting for the native
subagent prompt to finish, requires the parent prompt thread to still be live
after the child marker renders, and therefore proves an attached interactive
TUI while the subagent is active. Driver-only reverse requests remain root `2`,
child `1`, observer `0`.

Both bridge clients converged on one temporary Coinor-specific leader. Exact
root and hidden-child resumes each succeeded on the first attempt from an
unrelated cwd. The isolated run loaded no global hooks, required no global
leader setting, had no Herdr on its child `PATH`, and removed its temporary
leader and directory.

Detailed evidence: `Spikes/GrokSharedSession/RESULTS.md`.

## Hook relay spike

Production status: **SUPERSEDED.** This spike remains valid historical evidence
for lifecycle edge cases, but Coinor now consumes Grok's native ACP subagent
lifecycle directly and does not install or bundle the relay.

Status: **PASS**

Commands:

```sh
Spikes/HookSpike/run-tests.sh
scripts/hooks/verify.sh
```

Final automated result:

```text
Test run with 4 tests in 0 suites passed
Test run with 19 tests in 1 suite passed
```

Evidence:

- complete framed JSON delivery through the release relay and Unix listener
- payload framing completed before the relay forks
- immediate fail-open behavior with no socket, no listener, invalid JSON, or
  delivery failure
- detached child survives termination of the original hook process group
- duplicate, reordered, nested, cancelled, terminal-failure, and root-death
  lifecycle reconciliation
- ultimate-root identity preserved for every nested descendant
- real Grok `SessionStart`, `SubagentStart`, `SubagentStop`, and `SessionEnd`
  delivery
- real interactive cancellation without `SubagentStop`
- real abrupt root `SIGKILL` with descendant cleanup fallback

The Coinor registration under `~/.grok/hooks/` is ownership-marked,
idempotent, and refuses to overwrite unrelated hook files. It is inert when
Coinor's listener is absent. Verification also compares the installed relay
with Coinor's current release build so version skew is detected.

Detailed evidence: `Spikes/HookSpike/RESULTS.md`.

## Residual risks carried forward

- GhosttyKit's C API is unstable, so the header, static framework, resources,
  and commit pin must continue to move as one artifact.
- A fresh Ghostty source build requires Xcode's optional Metal Toolchain.
- The current artifact is arm64-only, matching Coinor's personal Apple Silicon
  target.
- Physical mixed-scale display movement and physical sleep/wake still require
  final app validation on suitable hardware.
- Native ACP lifecycle updates are the production source. Coinor recursively
  replays persisted updates after reconnects and while descendants are active.
- The Ghostty static archive emits two non-fatal missing-debug-symbol linker
  warnings from upstream `ext.o`.
- Grok protocol and native lifecycle payload contracts are runtime integration
  contracts; startup diagnostics and compatibility tests remain mandatory.

None of these residuals requires a forbidden dependency or a change to Grok,
so they do not block Phase 1.
