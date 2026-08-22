# Coinor Verification Record

Date: August 8, 2026

## Retired Grok Runtime Baseline

`scripts/phase0/check-boundaries.sh` and `docs/baselines/` were removed on
August 8, 2026. They pinned the Grok runtime checkout to the exact revision and
working-tree status recorded during Phase 0, which stopped describing reality
once Grok moved ahead. Entries below that cite the script are kept as the
historical record of the release they belong to.

The integration boundaries that still hold are enforced by the product and its
release verification: an absolute Grok path, Coinor's private leader socket,
and no writes into `grok-build` or `~/.grok/config.toml`.

## Conan Code 0.6.4 Verification

Version `0.6.4` build `42` ships two changes: an upstream-sync warning that
compares `jattento/grok-build`'s `main` against `xai-org/grok-build` via
GitHub's compare API and surfaces a small toolbar warning when the fork is
missing upstream commits, and Conan Code's first original app icon (an
illustration inspired by Jose's dog Conan, not a photo). See
`docs/releases/0.6.4.md`.

Automated verification:

- `scripts/dev/preflight.sh` passed on macOS 26.6.1 with Xcode 26.6 (17F113),
  macOS SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allowed, and automation mode requiring no
  authentication.
- `scripts/dev/run-tests.sh` ran repeatedly (597 tests in 45 suites). The new
  `GrokUpstreamSyncCheckerTests` cases (behind-upstream, caught-up, and an
  `AppShellModel` test driving the real checker end to end against synthetic
  GitHub compare payloads) and the new `AppShellIdentifier` pin test in
  `AppFoundationTests` passed on every run. The same pre-existing, load-
  sensitive subprocess wall-clock timing flakes documented for 0.6.3
  (`GrokSubprocessTransportShutdownTests.shutdownWaitsUntilTheChildProcessHasExited`,
  `executableVersionProbeKillsACommandThatWouldOtherwiseHang`) intermittently
  missed their bound only when run alongside the rest of the suite under this
  session's own background load (load average 5-8); each passes in isolation,
  and `git diff` against every one of those files is empty.
- Grok fork (`jattento/grok-build`): resynced with `xai-org/grok-build`
  (fetch, rebase, one real conflict resolved, push). `cargo check -p
  overlay-core && cargo test -p overlay-core` passed (29 tests, 0 failures),
  `cargo build -p xai-grok-pager-bin` succeeded, and
  `overlay/scripts/overlay-diff.sh` passed its touchpoint and delta-budget
  gates. GitHub's compare API confirms `ahead_by: 0` against
  `xai-org/grok-build`'s `main` after the push. A second, later-rebased
  commit called `SessionCommand::SetSessionModel` without the
  `is_family_switch` field a concurrent upstream commit had added (no
  textual conflict, so the rebase applied it silently); the fix was first
  verified only against the working tree and left uncommitted by the initial
  push. It is now commit `dffe84b`, with the delta budget updated via
  `overlay-diff.sh --update-budget --allow-growth`, and re-verified by
  cloning `origin/main` fresh and running `cargo check -p xai-grok-shell`
  against that clone.
- The arm64 Release build succeeded. `scripts/release/verify-app.sh` reported
  version `0.6.4 (42)`, arm64, macOS 13.0 minimum, deep-strict ad-hoc
  signature, App Sandbox disabled, `get-task-allow` absent, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `AppIcon.appiconset` (10 standard macOS sizes) confirmed present in
  `Assets.xcassets` and compiled to `Contents/Resources/AppIcon.icns` in the
  built bundle, matching `CFBundleIconName`.
- `git diff --check` passed; `scripts/release/security-scan.sh` passed over
  the tracked snapshot and every file in the release bundle for `coinor`;
  `gitleaks detect` over `grok-build` found only 8 pre-existing findings, all
  from a single upstream commit predating this sync and all sanitizer/test
  fixture strings (e.g. `xai-grok-secrets/src/sanitizer.rs`), none in files
  this sync touched.
- Installed `/Applications/Coinor.app` from the exact verified bundle after
  removing every stale duplicate; the running process, LaunchServices, and
  Spotlight all resolve to the canonical path, and its executable SHA-256
  matches the built artifact and version `0.6.4 (42)`.

## Conan Code 0.6.3 Verification

Version `0.6.3` build `41` ships four changes: native mouse routing in the
embedded terminal (verbatim event forwarding instead of a deferred-press,
synthesized-Shift router), an optimistic sidebar rename, automations that run
live through Conan Code's own control-plane connection when its GUI is
already running, and — in the Grok fork — proactive image handling for
no-vision ("NV") models. See `docs/releases/0.6.3.md`.

Automated verification:

- `scripts/dev/preflight.sh` passed on macOS 26.6.1 with Xcode 26.6 (17F113),
  macOS SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allowed, and automation mode requiring no
  authentication.
- `scripts/dev/run-tests.sh` ran repeatedly. Every run of the 7 XCUITests and
  the 589 non-timing-sensitive unit tests passed cleanly, including the new
  cases for the mouse-routing rewrite (button mapping, focus-transfer,
  pointer-exit sentinel, doubled precise scroll), the optimistic-rename
  rollback, and both branches of the live-automation hand-off (executed for
  real against a stub `grok` and stand-in `pgrep`/`open`, never the live
  system binaries). A small, fixed set of pre-existing, unrelated subprocess
  wall-clock timing tests
  (`GrokSubprocessTransportShutdownTests.shutdownWaitsUntilTheChildProcessHasExited`,
  `GitProcessRunnerDeadlineTests.oversizedOutputIsTruncatedThroughTheGitRunner`,
  `executableVersionProbeKillsACommandThatWouldOtherwiseHang`,
  `RemoteShellExecutionTests.stopCommandLeavesAProcessRunningFromAGrokDirectoryAlone`)
  intermittently missed a ~2-second wall-clock bound only when run alongside
  the rest of the suite; each was confirmed to pass in isolation in a
  fraction of a second, repeatedly, and none touches code this release
  changed (`git diff` against every one of those files is empty). This is the
  same load-sensitive flake class documented for earlier releases, not a
  regression.
- Grok fork (`jattento/grok-build`): `cargo test -p overlay-core -p
  overlay-conversation -p xai-grok-sampling-types -p xai-grok-sampler` passed
  (347 unit tests across the touched packages, 0 failures), and
  `overlay/scripts/overlay-diff.sh` passed its touchpoint and delta-budget
  gates with zero new upstream touchpoints — the no-vision fix reuses the
  fork's single existing conversation-preparation touchpoint in
  `overlay-conversation`.
- The arm64 Release build succeeded. `scripts/release/verify-app.sh` reported
  version `0.6.3 (41)`, arm64, macOS 13.0 minimum, deep-strict ad-hoc
  signature, App Sandbox disabled, `get-task-allow` absent, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `git diff --check` passed; `scripts/release/security-scan.sh` passed over
  the tracked snapshot and every file in the release bundle, with no leaks
  found, for both `coinor` and `grok-build`.

## Conan Code 0.6.2 Verification

The ego lite Browser Mirror feature (ADR-0016) ships as version `0.6.2` build
`40`: live read-only preview tabs of ego-browser Task Spaces, an "Open in ego
lite" action, automatic open/update/close driven by the passive ACP detector,
and the bundled `conan-code-browser` skill. The mirrored image now fills the
tab and crops (top-aligned) instead of letterboxing.

Automated verification:

- `scripts/dev/preflight.sh` passed on macOS 26.6.1 with Xcode 26.6 (17F113),
  macOS SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allowed, and automation mode requiring no
  authentication.
- `scripts/dev/run-tests.sh` passed end to end: 582 Swift Testing tests in 43
  suites, 46 XCTest cases, and 5 application-shell XCUITests with 0 failures.
  The opt-in live UI tests remained skipped because
  `COINOR_RUN_LIVE_BROWSER_MIRROR_UI` and `COINOR_LIVE_REMOTE_HOST` were not
  set.
- The arm64 Release build succeeded. `scripts/release/verify-app.sh` reported
  version `0.6.2 (40)`, arm64, macOS 13.0 minimum, deep-strict ad-hoc
  signature, App Sandbox disabled, `get-task-allow` absent, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- The bundled Ghostty manifest is byte-identical to
  `Vendor/Ghostty/manifest.txt`. The Release manifest resource had drifted
  from the verified artifact at commit `689df7a` (the artifact was rebuilt on
  Xcode 26 toolchains there); it is regenerated from the verified
  `Vendor/Ghostty` artifact (tag v1.3.1, commit `332b2aef`), whose
  `library_sha256`/`xcframework_sha256`/`resources_sha256`/`header_sha256`
  match the pinned values, and `scripts/ghostty/verify.sh --artifact-root
  Vendor/Ghostty` passes.
- `git diff --check` passed; `scripts/release/security-scan.sh` passed over 92
  commits, the tracked snapshot, and every file in the release bundle, with no
  leaks found.
- The published archive checksum (`Artifacts/SHA256SUMS`) is
  `755fbde8afa35eda3377775bb10d71c08fa0f595366339e8003a96d053aa972f`.

The Browser Mirror is covered by 1,434 lines of new and updated tests across
the passive detector, poller cadence, screenshot-client parsing, runtime tab
lifecycle (reuse, close, orphan, same-owner reopen), and a gated live E2E UI
test that drives the real `ego-browser` CLI when enabled.

## Conan Code 0.6.0 Verification

Scheduled automations, backed by launchd and run by `grok` itself, ship as
version `0.6.0` build `38`.

Automated verification:

- `scripts/dev/preflight.sh` passed on macOS 26.6.1 with Xcode 26.6 (17F113),
  macOS SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allowed, and automation mode requiring no
  authentication.
- `scripts/dev/run-tests.sh` passed end to end: 516 Swift Testing tests in 43
  suites, 46 XCTest cases, and 5 application-shell XCUITests. The opt-in live
  remote-host UI test remained skipped because `COINOR_LIVE_REMOTE_HOST` was
  not set.
- `scripts/release/verify-app.sh` reported version `0.6.0 (38)`, arm64, macOS
  13.0 minimum, deep-strict ad-hoc signature, App Sandbox disabled,
  `get-task-allow` absent, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` passed over 85 commits, the tracked
  snapshot, and every file in the release bundle, with no leaks found.

Automation-specific verification:

- Cron parsing and the launchd compiler are covered for wildcards, steps,
  ranges, lists, and month and weekday names, including that `0` and `7` both
  mean Sunday and are not emitted twice. Schedules that expand past the entry
  limit are rejected in the editor rather than handed to launchd.
- Every recurrence the schedule picker can produce is asserted to compile into
  at least one launchd calendar interval, and an expression the picker cannot
  describe round-trips through the custom mode unchanged.
- The generated job is asserted to invoke `grok` headlessly in the automation's
  project, with the shared instruction appended through `--rules`, permissions
  pre-approved, a freshly minted session per run, and the model pinned only
  when one is chosen.
- Command injection is proven by execution, not inspection: the generated
  script is run with a stub `grok` that records its argument vector, and a
  hostile prompt arrives as one intact argument while the injected command
  never runs.
- A live, opt-in test (`COINOR_RUN_LIVE_LAUNCHD=1`) installs a real job into
  the user's launchd domain, starts it through the same `kickstart` the Run Now
  control uses, and reads the recorded run back with its session identifier,
  then confirms removal unloads the job.
- The run log reader is covered for folding start and finish events, non-zero
  exit codes, newest-first ordering, partially written trailing lines, and logs
  written before runs recorded a trigger.

Manual verification:

- Creating an automation with the recurrence picker installed its launchd job;
  the automation then fired on its own schedule repeatedly and each run
  completed successfully.
- Run Now started a run immediately, the row and detail showed it in flight,
  and the run settled to a success state with its duration.
- Each run's conversation appeared in the sidebar under its project with the
  clock badge and was renamed after its automation.
- A finished run raised a native notification.

## Conan Code 0.5.29 Verification

Native Grok Workflows, complete live-subagent working state, and exact-once
Agent Search activation ship as version `0.5.29` build `36`.

Automated verification:

- `scripts/dev/preflight.sh` passed on macOS 26.6.1 with Xcode 26.6 (17F113),
  macOS SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allowed, and automation mode requiring no
  authentication.
- `scripts/dev/run-tests.sh` passed end to end: 46 XCTest cases, 394 Swift
  Testing tests in 33 suites, and 5 application-shell XCUITests. The opt-in
  live remote-host UI test remained skipped because `COINOR_LIVE_REMOTE_HOST`
  was not set.
- Workflow tests drive production JSON-RPC requests, snapshot/notification
  parsing, revision gating, cross-run event ordering, context-generation
  guards, launch argument validation, and status-specific controls.
- The real application UI opened the Workflows destination, exposed native
  refresh/back controls, and returned to the conversation.
- Subagent activity tests cover idle root plus live child, last-child finish,
  active root, and `needsInput` precedence. Agent Search tests cover exact text
  carry-over, single submission, whitespace-only input, dismissal, and repeat
  activation.
- The arm64 Release build, `scripts/release/verify-app.sh`, `git diff --check`,
  and `scripts/release/security-scan.sh` passed against the final bundle.
- The published archive checksum and GitHub asset digest matched, and the
  canonical `/Applications/Coinor.app` installation matched the public asset.

Manual/native verification covered normal and compact workflow layouts plus
loading/no-context behavior. Grok remains the owner of workflow scripts and run
state; Conan Code only presents and forwards user intent.

## Conan Code 0.5.28 Verification

Agent Search searches the conversations on disk instead of pasting them into a
prompt, and the unattended gate grew a check for what was then believed to be
the authorization right blocking XCUITest. That belief was wrong and a later
release replaced the check; see the automation mode section of
`docs/release.md`. Ships as version `0.5.28` build `35`.

The bug this release fixes: the finder inlined every candidate — title, project
and up to 2,000 characters of transcript excerpt — into one `-p` prompt. Grok
offloads any prompt over 25,000 bytes (`LARGE_PROMPT_THRESHOLD` in
`prompt_build.rs`) to a file and instructs the model to read it back with
`read_file`, which this finder listed as a disallowed tool. With a catalog of
420 conversations the prompt was roughly 927 KB against a 25 KB budget, so the
model saw a truncated fragment, could not read the offloaded remainder, and
answered confidently from whatever survived. It never disclosed the truncation.

Automated verification:

- `scripts/dev/preflight.sh` passed, then including
  `automation_mode_authorization=allow`. That key and its check no longer
  exist.
- `scripts/dev/test-preflight.sh` passed, then with cases for a missing
  `com.apple.dt.AutomationModeUI` rule and for a rule that is not `allow`. Its
  `security` shim answered both rights so the cases tested the script rather
  than whatever the host happened to have granted. Those cases are gone: that
  right governs nothing.
- `scripts/dev/run-tests.sh` passes end to end for the first time on this
  machine: 312 Swift Testing tests in 33 suites, 46 XCTest cases, and the
  XCUITest phase, with no authentication dialog. Earlier releases could not run
  XCUITest at all.
- `COINOR_RUN_LIVE_AGENTIC_FINDER=1` exercises the finder against the installed
  Grok: it writes the index, greps the transcripts named in it, and returns
  structured matches.
- New regression tests pin the defect directly: the prompt is byte-identical
  regardless of catalog size and stays under half the offload threshold, while a
  500-conversation index is deliberately larger than that threshold and lives
  only in the file.
- `scripts/release/verify-app.sh`, `git diff --check`, and
  `scripts/release/security-scan.sh` pass against the release candidate.

Manual verification against the user's real data: an index built from all 691
on-disk conversations (306 KB) was searched for the daily standup conversation
in `claude-sandbox`. The finder read the index, grepped the transcripts, and
returned both `Keyway Daily Standup` sessions plus three related ones in 40
seconds over five turns. The previous implementation reported that no such
conversation existed.

## Conan Code 0.5.27 Verification

A dismissible Agent Search panel, context-scoped remote-disconnect
notifications, and a Conan Code-native `sidechat` skill ship as version
`0.5.27` build `34`.

Automated verification:

- `scripts/dev/preflight.sh` passes: macOS 26.5.1, Xcode 26.6 (17F113), macOS
  SDK 26.5, Swift 6.3.3, Developer Tools security enabled,
  `system.privilege.taskport` allow, writable build and temp directories.
- Swift 6 Debug and Release builds succeed.
- The hosted unit suite runs green through `scripts/dev/run-tests.sh`: 305
  Swift Testing tests in 33 suites plus 46 XCTest cases, 0 failures. That suite
  now also drives the Agent Search dismissal unit, the remote-disconnect
  predicate across the full context matrix, and the shipped `sidechat.sh`
  against a stub control client that answers exactly what
  `TerminalControlServer` answers.
- `scripts/dev/run-tests.sh` itself was broken for the documented
  no-extra-arguments invocation (bash 3.2 rejects `"${empty[@]}"` under
  `set -u`) and is fixed.
- `scripts/release/verify-app.sh` passes and now also pins the bundled
  `sidechat-SKILL.md` / `sidechat.sh` to their sources and parses the script.
- `git diff --check` passes; `scripts/release/security-scan.sh` passes against
  the release candidate bundle.

XCUITest was unrunnable unattended on this machine at the time of this release.
`testmanagerd` raised a SecurityAgent authorization prompt — *"XCTest is trying
to Enable UI Automation"* — that required Touch ID or the account password, and
the runner failed with `Timed out while enabling automation mode` before any
test executed. This release does not claim a completed XCUITest run. The
remedy, found later, is `automationmodetool
enable-automationmode-without-authentication`; no `security authorizationdb`
write affects this gate.

Manual and automated UX verification was performed instead through `peekaboo`
4.0.0, which does hold Screen Recording and Accessibility, against a running
build with the real sidebar populated:

- The Agent Search panel exposes a `Close Agent Search` control; clicking it
  returns the finder to not-presented and flips the sparkle toggle back to
  `Off`.
- Escape sent to the application dismisses the panel from the same state.
- With a registered but unreachable remote computer (`jattentom2-home`), the
  sidebar badge reports `Remote computer …, unavailable` while a purely local
  context raises no disconnect notification.

## Conan Code 0.5.26 Verification

Conversation ordering, immediate archive behavior, remote disconnect episodes,
and ephemeral Agent Search ship as version `0.5.26` build `33`.

Automated verification:

- The Swift 6 Debug application build succeeds with the new search, ordering,
  archive, and notification code.
- Focused tests cover newest-first catalog construction, stable explicit order,
  project archive unpinning, one-notification-per-disconnect episodes, Agent
  Search response sanitization/action filtering, bounded result count, safe
  headless flags, and quoted remote transcript export.
- The canonical hosted XCTest runner was attempted after terminating the
  installed application, but the app-host launch remains blocked in this
  machine's test-host environment. This release does not claim a completed
  hosted XCTest/XCUITest run; compile checks and the independently runnable
  focused verification are recorded instead.
- Release arm64 build, bundle verification, Ghostty artifact verification,
  security scanning, checksum comparison, and installed-bundle identity are
  required before publication and are recorded in the public release notes.
- `git diff --check` passes.

Manual UX verification checks the integrated sidebar search mode, compact
mini-chat layout, explicit result actions, immediate archive disappearance,
remote unavailable badge/reconnect affordance, and the absence of a persistent
remote warning. Agent Search state is also checked after closing and reopening
the search surface.

## Conan Code 0.5.25 Verification

Switching terminal tabs no longer costs work proportional to the whole
catalog, as version `0.5.25` build `32`.

Automated verification:

- 273 swift-testing tests across 33 suites passed with 0 failures, including
  the new `stopCommandLeavesAProcessRunningFromAGrokDirectoryAlone`.
- 46 XCTest cases passed with 0 failures, and 3 XCUITest cases passed with 1
  skip, from the canonical `xcodebuild test` with no patched harness. The
  installed application was quit first, because both bundles declare
  `dev.coinor.Coinor` and LaunchServices refuses the second one.
- Release arm64 build passed.
- `scripts/release/verify-app.sh` reported `0.5.25 (32)`, arm64, macOS 13
  minimum, deep-strict signature, sandbox disabled, source-matched terminal
  control resources, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` found no leaks in Git history, the
  publishable snapshot, or the Release bundle.
- `git diff --check` passed.

The tab-switch cost was established by tracing the work a single selection
performs, not by timing it. Selecting a tab published tab metadata, which
scheduled an immediate full metadata write and then `rebuildCatalog()`. That
rebuild runs `SessionCatalog.build` over every session and project and
republishes `catalog` and `metadata` on the window-wide coordinator, so the
sidebar re-rendered on every tab click. Nothing the sidebar displays depends on
which terminal tab is selected, so the rebuild is now skipped and the write is
coalesced per conversation behind a settle delay, with a flush before the
persistence drain so quit and restart cannot lose a pending selection.

A separate defect was found while running the suite from a worktree under
`~/.grok`. `RemoteRuntimeStopCommand` identified the remote leader with
`ps -o command=`, which prints the whole argument vector including the
executable path, and matched the substring `grok`. The test host built inside
`~/.grok/worktrees/...` therefore matched its own guard and was killed by
`stopCommandIgnoresAPIDThatIsNotGrok`, which reads as an unexplained
`Restarting after unexpected exit` and an aborted run. The guard now reduces
`ps -o comm=` to the executable name before matching. The behaviour is pinned
by `stopCommandLeavesAProcessRunningFromAGrokDirectoryAlone`, which runs a real
process from a `.grok` directory, records its PID in the lock, and asserts it
survives the stop command; that test fails against the previous guard.

## Conan Code 0.5.24 Verification

An ordinary click now reaches the application that captured the mouse, as
version `0.5.24` build `31`.

Automated verification:

- 272 swift-testing tests across 33 suites passed with 0 failures, including
  the two new cases that hold the click contract:
  `capturedClickSurvivesJitterUnderTheDragThreshold` and
  `capturedGesturePromotesOnceTravelPassesTheDragThreshold`.
- 46 XCTest cases ran with one failure,
  `testApplicationBundleMatchesTheDeclaredIdentity`, caused by the test harness
  and not by the product. The canonical `xcodebuild test` cannot launch its
  host while an installed Conan Code is running, because both bundles declare
  `dev.coinor.Coinor` and LaunchServices refuses the second one. The suite was
  therefore run from a patched `.xctestrun` against a copy of the host renamed
  to `dev.coinor.CoinorFixTest`, which is exactly the identity that assertion
  rejects. `scripts/release/verify-app.sh` independently reports
  `verified_bundle_id=dev.coinor.Coinor` for the shipped bundle, so the
  assertion holds for the released application.
- Release arm64 build passed.
- `scripts/release/verify-app.sh` reported `0.5.24 (31)`, arm64, macOS 13
  minimum, deep-strict signature, sandbox disabled, source-matched terminal
  control resources, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` found no leaks in Git history, the
  publishable snapshot, or the Release bundle.
- `git diff --check` passed.

The defect and the fix were both established from raw terminal input rather
than from inspection. A managed tab enabled mouse tracking modes `1000`,
`1002`, `1003`, and `1006` plus focus reporting `1004`, and dumped every byte
the application received:

- Three ordinary hand clicks produced only motion reports, `ESC [ < 35 ; C ; R
  M`, and not one button report. The clicks were invisible to the running
  application.
- A synthesized click, which cannot jitter between press and release, produced
  the complete `ESC [ < 0 ; C ; R M` and `ESC [ < 0 ; C ; R m` pair.

That difference isolates hand jitter as the cause. A deferred captured gesture
was promoted to a text selection on the first pointer movement of any size, a
promoted gesture is routed with Shift forced on, and `GhosttyOverrides.conf`
sets `mouse-shift-capture = never`, so `Surface.zig` consumed the gesture
locally instead of reporting it. Grok's interface arms an affordance such as
`[Copy Source]` on the press and executes it on the release, so losing both
reports lost the click.

Manual verification ran the fixed build as a second, isolated instance beside
the installed application, using its own application support directory and its
own Grok leader socket:

- A single ordinary click on `[Copy Source]` under a Grok-rendered diagram
  copied the diagram source on the first attempt.
- Dragging to select terminal text still selects text.

## Conan Code 0.5.23 Verification

A find request now goes to whoever holds the text, as version `0.5.23` build
`30`.

Automated verification:

- Full Debug suite: 46 XCTest cases, 270 swift-testing tests across 33 suites,
  and 3 XCUITests passed with 0 failures.
- Release arm64 build passed.
- `scripts/release/verify-app.sh` reported `0.5.23 (30)`, arm64, macOS 13
  minimum, deep-strict signature, sandbox disabled, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` found no leaks in Git history, the
  publishable snapshot, or the Release bundle.
- `git diff --check` passed.

Manual verification used a live window against an isolated application support
directory:

- A new Grok conversation was started, its prompt focused, and `Cmd+F` wrote
  `/find ` into the prompt with Grok's own argument placeholder, ready for the
  text to look for. Nothing was submitted.
- The scrollback limitation was confirmed at the source: Ghostty gives an
  alternate screen `max_scrollback = 0` (`src/terminal/Terminal.zig`), and its
  search honours `no_scrollback` (`src/terminal/search/screen.zig`), so a
  terminal-level search in a full-screen program is screen-deep by
  construction.

## Conan Code 0.5.22 Verification

The sidebar draws its own rows and `Cmd+F` searches a terminal as version
`0.5.22` build `29`.

Automated verification:

- Full Debug suite: 43 XCTest cases, 270 swift-testing tests across 33 suites,
  and 3 XCUITests passed with 0 failures. The remote XCUITest stays skipped
  without `COINOR_LIVE_REMOTE_HOST`.
- Release arm64 build passed.
- `scripts/release/verify-app.sh` reported `0.5.22 (29)`, arm64, macOS 13
  minimum, deep-strict signature, sandbox disabled, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` found no leaks in Git history, the
  publishable snapshot, or the Release bundle.
- `git diff --check` passed.

Manual verification used a live window of the Debug build and a smoke run of
the Release bundle, both against an isolated application support directory:

- The sidebar showed project headers with their icon, conversations indented
  under the project title, one selected row pill, and full-width titles that
  no longer truncate around reserved control space.
- `Cmd+F` in the Grok pane opened the find bar over the terminal, above the
  Metal layer, with the field focused.
- Typing `property` highlighted every match in the scrollback and the bar
  reported `9`; `Return` moved to the first match and the bar reported `1/9`.

## Conan Code 0.5.12 Verification

The sidebar stopped relying on `DisclosureGroup` for project rows as version
`0.5.12` build `19`, so a collapsed project header can no longer inherit the
indentation `List` reserves for the conversations inside it.

Automated verification:

- Full Debug suite: 34 unit and integration tests plus 3 XCUITests passed with
  0 failures and 0 skips.
- Release arm64 build passed.
- `scripts/release/verify-app.sh` reported `0.5.12 (19)`, arm64, macOS 13
  minimum, deep-strict signature, sandbox disabled, and Ghostty commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/release/security-scan.sh` found no leaks in Git history, the
  publishable snapshot, or the Release bundle.
- `git diff --check` passed.
- The published asset digests matched the local `SHA256SUMS`.

Manual verification used the installed application and its live window:

- Accessibility geometry reported every project header on the same leading
  edge, with conversation rows one indent inside them.
- Clicking a project header and its chevron toggled expansion, and project
  reordering by drag still committed.
## Conan Code 0.5.13 Verification

Remote host support shipped as version `0.5.13` build `20` on August 8, 2026.

- The full Debug test suite passed with 0 failures.
- The arm64 Release build passed.
- `scripts/release/verify-app.sh` passed for the exact Release bundle:
  `verified_codesign=deep-strict`, `verified_app_sandbox=false`,
  `verified_get_task_allow=false`,
  `verified_ghostty_commit=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`,
  `verified_coinorctl_outside_app_error=stable`.
- `scripts/release/security-scan.sh` found no secrets or private local paths.
- `git diff --check` passed.

## Conan Code 0.5.14 Verification

Remote host support was exercised end to end against a real second Mac reached
through its `~/.ssh/config` alias, using the production types rather than
hand-written commands.

Through Conan Code's own code (`CoinorTests/RemoteHostLiveTests`, enabled by
`COINOR_LIVE_REMOTE_HOST`):

- `RemoteHostProbe` reported the remote home, Grok executable, version, runtime
  socket, and `MaxSessions` in one round trip, and its socket is never the one
  that computer's own Conan Code uses.
- `GitProjectResolver(remote:)` resolved a real remote repository into a
  host-qualified project identity.
- `RemoteProjectDiscovery` listed remote directories and repositories.
- `fresh` and `lazygit` were confirmed present on the remote computer.
- Twelve concurrent channels shared one multiplexed connection.

On a real pseudo-terminal, which is what a Ghostty surface provides:

- A remote shell tab started the remote user's interactive login shell in the
  requested directory, confirmed by `$PWD` and `hostname` from that computer.
- The remote IDE commands started: `fresh .` entered the alternate screen with
  mouse reporting, and `lazygit` ran inside a real remote repository.
- A remote Grok conversation started and painted its interface with full mouse
  reporting; `--resume` of an existing remote conversation painted without a
  missing-session error, and the remote roster then reported that session as
  resident.
- Stopping the remote runtime terminated only Conan Code's remote leader; the
  leader owned by that computer's own Conan Code kept running.

Offline execution evidence (`CoinorTests/RemoteShellExecutionTests`,
`CoinorTests/SSHInvocationExecutionTests`): every composed remote command is
executed in a real shell, and the real `ssh` binary accepts Conan Code's option
set and reports a failed connection as 255.

Findings corrected during this pass:

- Stopping a remote runtime sent one `SIGTERM` and returned before the leader
  exited. It now waits and escalates to `SIGKILL`, mirroring the local path.
- The compatibility probes sent this computer's home directory to the remote
  agent as a `cwd`. They now send the remote home.
- macOS reports a denied local-network connection as an undefined error, which
  looked like a broken network. `NSLocalNetworkUsageDescription` was added and
  the diagnostic now names the permission.
- `~/.ssh/config` inline comments were parsed as additional host aliases.

## Conan Code 0.5.21 Verification

A registered computer that became unreachable stayed unreachable: the periodic
refresh only iterated hosts that were already connected, so a computer that had
been asleep or restarted could only be recovered by removing and adding it
again.

The refresh now retries every registered host that has no runtime or is marked
unreachable, quietly, and the remote computers view offers an explicit
`Reconnect` and shows the reason the computer is unavailable.

- A live test registers a host, stops its remote runtime underneath it, and
  requires a fresh connection to succeed and read the catalog again. It passed
  against a real second Mac.
- The full suite passed with 0 failures.

## Conan Code 0.5.20 Verification

The colour guarantees of an embedded terminal are now asserted directly rather
than inferred: `TerminalSurfaceEnvironment.variables` is built outside the
AppKit surface, and tests require every local and remote surface to carry
`COLORTERM=truecolor` and to never carry `NO_COLOR`. The start-up removal of an
inherited `NO_COLOR` keeps its own test.

Manual confirmation on the installed application: launched with `NO_COLOR=1`
in its environment, every terminal process it started reported
`TERM=xterm-ghostty`, `COLORTERM=truecolor`, and no `NO_COLOR`.

This computer's `~/bin/grok` now points at the installed
`v0.2.117-overlay.3` release instead of the development worktree launcher, so
both computers report the same version and the host version warning is gone.

The full suite passed with 0 failures.

## Conan Code 0.5.19 Verification

Grok offered only its two non-truecolor themes, locally and remotely.

Two independent causes, both Conan Code's:

- Grok treats `NO_COLOR` as set even when empty, so it cannot be neutralized
  through Ghostty's per-surface variables. A value inherited from whatever
  launched the application reached every embedded terminal. The application now
  removes it from its own environment at start-up, before any surface exists;
  a shell running inside a terminal can still set it.
- SSH forwards `TERM` but never `COLORTERM`, so a remote pane's Grok saw a
  downgraded terminal. Remote Grok, shell, and IDE commands now carry
  `COLORTERM=truecolor`, and local surfaces set it explicitly.

Evidence: on a real remote computer, the previous command reported
`COLORTERM=<unset>` in the remote login shell and the new one reports
`truecolor`. `grok doctor` in a clean pseudo-terminal reports
`color truecolor` and `themes all`, and with `NO_COLOR` set it reports
`2/7: groknight, grokday`, which is exactly what the picker showed.

The full suite passed with 0 failures.

## Conan Code 0.5.18 Verification

Opening a conversation in a remote project showed
`The terminal working directory is unavailable` instead of a terminal.
`TerminalSurfaceRepresentable` checked the conversation's working directory
against this computer's file system, and a remote conversation's directory
exists only on the other computer.

The check now lives on `TerminalLaunchRequest.surfaceStartupFailure()`, which
skips the file-system check for a remote launch and still reports an
unresolved directory. Every other local file-system check was re-audited: the
rest cover this computer's own Grok binary, Ghostty resources, metadata, and
the local-only terminal-control service.

- `CoinorUITests/RemoteHostUITests` now also starts a conversation in the
  remote project it just added and fails if the unavailable-directory message
  appears; it passed end to end against a real second Mac.
- Unit tests cover local missing, local present, remote, and unresolved
  directories.
- The full suite passed with 0 failures.

## Conan Code 0.5.16 Verification

Registering a remote computer failed on its first step with
`keyword controlpath extra arguments at end of line`. Conan Code's SSH control
socket lives under `Application Support`, and OpenSSH's own option lexer splits
`-o` values on whitespace, so the space in that path was read as a second
argument. The value is now quoted.

The reason no test caught it is recorded deliberately: every SSH test, and the
remote-host UI test, ran against an isolated support directory under `/tmp`
with no space in its path, so they exercised a path shape the product never
uses.

- `CoinorTests/ControlPathRegressionTests` now runs the real `ssh` binary with
  the real default control path and fails if OpenSSH rejects it again.
- The SSH invocation tests use a directory whose name contains a space.
- `CoinorUITests/RemoteHostUITests` isolates into a directory whose name
  contains a space, and passed end to end against a real remote computer:
  registering, `Connected`, adding a remote project through the picker, the
  host badge, and removal.
- The full suite passed with 0 failures.

## Conan Code 0.5.15 Verification

Hiding remote projects and the remote computers empty state shipped as version
`0.5.15` build `22`.

- The full test suite passed with 0 failures.
- The arm64 Release build, `scripts/release/verify-app.sh`, and
  `scripts/release/security-scan.sh` passed.
- The reported empty `Remote Computers` panel was correct: that installation
  had no registered computer. The confusing part was its guidance, which sent
  the user back to the menu they had just used; it now registers a computer
  from the panel itself. The add sheet was confirmed to offer the four aliases
  in that machine's SSH configuration.

## Conan Code remote host interface verification

`CoinorUITests/RemoteHostUITests` drives the running application against a real
remote computer, in an isolated support directory so the user's own projects,
pins, and registered computers are untouched:

- The sidebar's `Remote Computers` menu opens `Add Remote Computer…`, which
  offers the alias from `~/.ssh/config` without any typing.
- Registering performs a real SSH health check and the management view then
  reports the computer as `Connected`.
- `Add Project` offers `From Remote Computer`, the picker lists repositories
  discovered on that computer, and selecting one registers the project. No
  path is typed anywhere in the flow.
- The new project appears in the same flat sidebar list carrying its host
  badge.
- Removing the computer returns the interface to its empty state.

## Conan Code remote host operations verification

Every remaining remote operation was exercised against the same real second
Mac, through Conan Code's own types.

Live suites (`CoinorTests/RemoteHostLiveOperationsTests`):

- Renaming a remote conversation went through that computer's leader and the
  original title was restored afterwards.
- The subagent lifecycle API answered for a real remote conversation.
- A worktree plan resolved entirely on the remote computer, with remote paths
  that do not exist on this one.

Real pseudo-terminals (`scripts/verify/remote-panes.py`, driven by the commands
`CoinorTests/RemoteLaunchCommandDumpTests` dumps from `TerminalLaunchRequest`
itself, so the script runs exactly what the product runs):

- A remote shell tab ran the remote login shell in the requested directory.
- The IDE tab started `fresh` and `lazygit` on the remote computer.
- A new remote conversation painted the Grok interface.
- An existing remote conversation resumed, and the same conversation
  reattached after the connection dropped.

Real subagent panel, end to end: a prompt sent to a remote conversation spawned
a subagent on that computer, its lifecycle event arrived over the remote ACP
stream, and resuming the child session opened a painted pane with no
missing-session error.

The pane checks live in a script rather than the test bundle because this
application's test host cannot fork a pseudo-terminal safely: the Ghostty
renderer's threads make `forkpty` inside it unreliable.

## Conan Code remote hosts verification

Remote host support (ADR-0014) was validated on August 8, 2026 against a real
second Mac reached through its `~/.ssh/config` alias.

Automated verification:

- The full test suite passed with 0 failures, including the new remote SSH,
  project identity, discovery, reconnect-policy, version-policy, and metadata
  suites.
- Debug and test builds passed.

Live verification against a real remote Mac:

- The probe script returned the remote home directory, Grok executable, version,
  runtime socket path, and `MaxSessions` in one SSH round trip.
- `ssh <host> 'grok --leader-socket <remote socket> agent --leader stdio'`
  completed the ACP handshake and answered `_x.ai/sessions/list` with that
  computer's real session roster.
- The remote leader started as `grok agent leader --no-exit-on-disconnect`,
  reparented to `launchd` (PPID 1) in its own process group, and remained alive
  after the SSH channel closed.
- The remote leader bound `grok-leader-remote.sock`, separate from the
  `grok-leader.sock` used by that computer's own Conan Code installation.
- Stopping the remote runtime through the lock-file PID path succeeded and left
  no leader process behind.

Findings corrected during verification:

- The remote leader's command line does not repeat `--leader-socket`, so
  stopping it by command-line pattern never matched. It is now stopped by the
  PID in the lock file beside its socket, mirroring the local path.
- `~/.ssh/config` inline comments were parsed as additional host aliases.
- Two machines on the same base Grok version can run different overlay builds,
  so the compatibility gate requires an equal base version and warns instead of
  refusing when only the overlay differs.

## Conan Code 0.5.5 Verification

The embedded Ghostty terminal theme was aligned with the Codex desktop app's
"Codex Dark" theme card (surface, accent, and a warm foreground) as version
`0.5.5` build `12` and validated on August 8, 2026.

Automated verification:

- 213 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITests passed with 0 failures and 0 skips.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed for Ghostty
  tag `v1.3.1`, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, or the Release bundle.
- `git diff --check` passed.
- The archive checksum verified.

Final Xcode result bundle:

```text
.build/DerivedData/Logs/Test/Test-Coinor-2026.08.08_15-18-10--0300.xcresult
```

Manual verification used a rendered mockup of the exact tab-strip and
terminal chrome, driven by the same hex values now in
`GhosttyOverrides.conf` and `AccentColor.colorset`:

- The selected-tab underline and terminal cursor both render the new
  `#339cff` accent; every other UI element that previously used
  `Color.accentColor` was confirmed to be limited to that one underline, so
  no other chrome changed.
- Tab labels, close/add controls, and terminal body text render the new
  `#faf3dd` warm foreground with contrast against `#181818` improved
  slightly over the previous `#e8e8e8` (16.0:1 vs 14.5:1).
- The ANSI palette used for command output (diff/status colors) is
  visually unchanged.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.5` build `12` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.5-arm64.zip` |
| Archive size | `6,000,608` bytes |
| Archive SHA-256 | `83bb3de31718c60978ef6d5c10a7ac44b049c812a1a1026a43bd8ee394ebf03b` |

## Conan Code 0.5.4 Verification

The startup loading screen's ASCII mascot artwork was replaced as version
`0.5.4` build `11` and validated on August 8, 2026.

Automated verification:

- 34 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITests passed with 0 failures and 0 skips.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed for Ghostty
  tag `v1.3.1`, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, or the Release bundle.
- `git diff --check` passed.
- The archive checksum verified.

Final Xcode result bundle:

```text
.build/DerivedData/Logs/Test/Test-Coinor-2026.08.08_15-02-15--0300.xcresult
```

Manual verification used the real Release application:

- The new ASCII artwork rendered cleanly on the startup screen in place of
  the previous dog drawing, with the "CONAN" caption, "Connecting to Grok"
  status text, and startup diagnostics panel unaffected.
- No other view, layout, or behavior changed.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.4` build `11` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.4-arm64.zip` |
| Archive size | `5,999,162` bytes |
| Archive SHA-256 | `03405903ddd898afb4bf6d644714960f777770947b34ba5f530c85aedd6ec1b5` |

## Conan Code 0.5.3 Verification

The embedded Ghostty theme rework was integrated as version `0.5.3` build
`10` and validated on August 8, 2026.

Automated verification:

- 216 unit, integration, and XCUITest cases passed with 0 failures and 0
  skips.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed for
  Ghostty tag `v1.3.1`, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, or the Release bundle.
- `git diff --check` passed.
- The archive checksum verified, and `diff -qr` found no difference between
  the built and archive-extracted application bundles.

`GhosttyOverrides.conf` was validated independently of the shipped bundle
before it was ever built into it: a standalone probe linked against the
real GhosttyKit static library loaded the machine's actual Ghostty config
(XDG `theme = Monokai Pro` plus the standalone Ghostty.app's own violet
Application Support override) and then applied `GhosttyOverrides.conf` on
top, exactly matching `GhosttyConfiguration.swift`'s load order. Result: 0
diagnostics, and background/foreground/cursor/selection/palette all
resolved to the new theme's exact intended values, proving the override
fully wins over the shared host config. A second, isolated GhosttyKit-linked
preview window (not the shipped Phase 0 spike, not the installed
application) rendered the palette with the real Metal renderer for visual
review.

Manual verification opened the exact Release bundle with the running
`Coinor.app` quit first (Conan Code holds a single-instance lock, which also
blocks the XCUITest runner from launching its own copy while another
instance is up). The IDE pane (`fresh` + `lazygit`) rendered the new neutral
palette cleanly against the sidebar. Quitting and relaunching Conan Code did
not disturb any live Grok leader or session process: all Grok processes
remained running throughout, and the app reconnected to the same
conversations it had open before the rebuild.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.3` build `10` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.3-arm64.zip` |
| Archive size | `5,998,921` bytes |
| Archive SHA-256 | `997d219bc9edc28a4e462bcd29ec38c49d691b7e4c2304793449e5a1c461db42` |

## Conan Code 0.5.2 Verification

Global previous and next conversation keyboard navigation was integrated as
version `0.5.2` build `9` and validated on August 8, 2026.

Automated verification:

- 179 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITests passed with 0 failures and 0 skips.
- `SidebarConversationNavigation` and `ConversationNavigationShortcut` tests
  covered adjacent movement, list boundaries, a hidden selection, an empty
  visible list, and the window-local shortcut monitor including event
  repeats.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed for
  Ghostty tag `v1.3.1`, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle and the
  archive-extracted application.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history or the publishable source snapshot.
- `git diff --check` and shell syntax checks passed.
- The archive checksum verified, and `diff -qr` found no difference between
  the built and archive-extracted application bundles.

Manual verification confirmed the Release build launches and exposes its
main window to Accessibility automation with the new commands installed; the
shortcut's navigation logic itself is exercised by the automated
`SidebarConversationNavigation`, `ConversationNavigationShortcut`, and
window-monitor tests, which drive the exact runtime `handle()` dispatch path
with real `NSEvent` instances rather than a UI double.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.2` build `9` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.2-arm64.zip` |
| Archive size | `5,984,633` bytes |
| Archive SHA-256 | `9e253fe29da0b410669139d6686d0ffde80971c1da6f3ffff4514f8916115003` |

## Conan Code 0.5.1 Verification

The precise terminal-scroll correction and automatic long-running terminal
policy were integrated as version `0.5.1` build `8` and validated on August 8,
2026.

Automated verification:

- 207 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITests passed with 0 failures and 0 skips.
- Focused scroll mapping tests covered precise and discrete input, including
  every Ghostty momentum phase.
- A natural service request selected a managed tab automatically, started a
  real Python HTTP server, returned HTTP 200, exposed logs, interrupted the
  process, closed the tab, and left no listener behind.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed for Ghostty
  tag `v1.3.1`, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- `scripts/ghostty/test-verification.sh` passed its happy path and all four
  corruption cases.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle and the
  archive-extracted application.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, or the Release bundle.
- `git diff --check`, Xcode project lint, and shell syntax checks passed.
- The archive checksum verified, and `diff -qr` found no difference between
  the built and archive-extracted application bundles.

Final Xcode result bundles:

```text
.build/DerivedData-0.5.1-final/Logs/Test/Test-Coinor-2026.08.08_11-47-55--0300.xcresult
.build/DerivedData-0.5.1-final/Logs/Test/Test-Coinor-2026.08.08_11-53-34--0300.xcresult
```

Manual verification used the real Release application with isolated
Application Support, embedded Ghostty, and the real custom Grok binary:

- Native sidebar scrolling moved through the populated project catalog and
  returned to its original position without a behavior change.
- A `0.05`-page precise upward gesture in populated main scrollback advanced
  only a few terminal lines instead of being treated as a discrete wheel tick.
- Main, IDE, and ordinary shell tabs were selected in the Release build. Their
  Ghostty surfaces share the single verified scroll-event mapper.
- The QA application quit cleanly with no Coinor or Grok child processes left.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.1` build `8` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.1-arm64.zip` |
| Archive size | `5,992,388` bytes |
| Archive SHA-256 | `21c16c167fa8d172ba9d1e5712a575e32486edbb06f475401b84dc053f2683a3` |

## Conan Code 0.5.0 Verification

The agent-managed terminal feature was implemented in an isolated worktree,
rebased explicitly onto local and remote `main` at `896babb`, prepared as
version `0.5.0` build `7`, and validated on August 8, 2026.

Automated verification:

- Debug `build-for-testing` passed.
- 203 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITests passed with 0 failures and 0 skips after macOS Automation Mode
  was temporarily authorized. The no-authentication configuration was removed
  immediately after the run; Automation Mode finished disabled and again
  requires user authentication.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed.
- `scripts/ghostty/test-verification.sh` passed its happy path and all four
  corruption cases.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle and the
  archive-extracted application.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, the Release bundle, or the
  archive-extracted bundle.
- `git diff --check`, Xcode project lint, and shell syntax checks passed.
- The archive checksum verified, and `diff -qr` found no difference between
  the built and archive-extracted application bundles.

Final Xcode result bundles:

```text
.build/TestResults-0.5.0-unit-retry.xcresult
.build/TestResults-0.5.0-ui-authorized.xcresult
```

Manual verification used the real Debug and Release applications, embedded
Ghostty, Fresh, Lazygit, the bundled `coinorctl`, the installed Grok skill, and
the real custom Grok binary:

- A root Grok agent created a visible managed tab in the background without
  changing the selected tab.
- Sequential commands reused one zsh process and preserved an exported
  variable and `/tmp` working directory.
- Incremental reads, raw text input, Enter, Ctrl-C, status, exact exit codes,
  explicit close, and post-close `tab_gone` behavior passed.
- A real native subagent created, operated, and closed its own managed tab
  using an opaque capability unavailable to other sessions.
- Relaunch restored only permanent `main` and `IDE`; managed tabs, processes,
  capabilities, and scrollback were not restored.
- Running the bundled helper outside Conan Code returned the stable
  `not running inside Conan Code` error without a fallback process.
- Confirmed conversation archive stopped the root Grok client, subagents,
  Fresh, Lazygit, ordinary shells, managed tabs, services, and their child
  processes immediately. The durable Grok session remained available to
  unarchive.
- The final IDE view retained the larger Fresh pane and a Lazygit pane wide
  enough to avoid its collapsed layout, with no overlap or focus regression.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.5.0` build `7` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.5.0-arm64.zip` |
| Archive size | `5,991,757` bytes |
| Archive SHA-256 | `50792115f473245408185a30c53455c64cda38b26ad82e358620131e74d8f7c8` |

## Conan Code 0.4.0 Verification

The permanent IDE workspace was rebased onto local and remote `main` at
`f0c6177`, prepared as version `0.4.0` build `6`, and validated on August 8,
2026. The release keeps the repository, bundle identifier, executable, and
application-support paths named Coinor for compatibility.

Automated verification:

- Fresh and Lazygit resolved from a clean Finder-compatible PATH as
  `/opt/homebrew/bin/fresh` and `/opt/homebrew/bin/lazygit`.
- Debug and Release arm64 builds passed from the versioned candidate.
- 195 unit and integration tests passed with 0 failures and 0 skips.
- 3 XCUITest passed with 0 failures and 0 skips.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed.
- `scripts/ghostty/test-verification.sh` passed its happy path and all four
  corruption cases.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle and for
  the application extracted from the final archive.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, the Release bundle, or the
  archive-extracted bundle.
- `git diff --check` passed for staged and unstaged changes.
- The archive checksum verified, and `diff -qr` found no difference between
  the built and archive-extracted application bundles.

The final Xcode result bundle is:

```text
.build/DerivedData-0.4.0/Logs/Test/Test-Coinor-2026.08.08_01-03-56--0300.xcresult
```

Manual verification used the real Debug and Release applications, embedded
Ghostty, Fresh, Lazygit, and the real custom Grok binary:

- Every loaded conversation displayed fixed `main` and `IDE` tabs before any
  shell tabs.
- `Command-2` selected IDE, `Command-W` was inert there, and `Command-T`
  created a shell in the third position. Closing that shell selected IDE.
- Fresh ran `fresh .` in the larger left pane and Lazygit ran in the right
  pane. The wide layout measured approximately 59.6/40.4 and remained stable;
  the existing compact layout activated when the window was narrow.
- Fresh and Lazygit both used the persisted Git root for the Coinor and
  rent-roll-debugger conversations.
- A historical deleted worktree displayed its exact missing-directory error in
  both panes without crashing or starting orphan processes.
- Switching conversations preserved the hidden Fresh and Lazygit processes.
  Two retained IDE pairs remained near 0% CPU, with observed child RSS of
  roughly 20-34 MB each.
- Normal quit stopped the application, Grok clients, Fresh, Lazygit, the
  private leader, and removed the private leader socket.
- The exact Release candidate restored the catalog, selected IDE state, and
  rendered the two-pane workspace without overlap.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.4.0` build `6` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.4.0-arm64.zip` |
| Archive size | `5,910,717` bytes |
| Archive SHA-256 | `22883d645b82c5e6a090978d2266f7a68cafcc990a65b7a3b4e21ccb6f3b13be` |

## Conan Code 0.3.1 Verification

The Conan Code presentation and interaction polish was rebased onto
`origin/main` at `5a343ec`, prepared as version `0.3.1` build `5`, and
validated on August 8, 2026. The repository, bundle identifier, executable,
and application-support paths remain named Coinor for compatibility.

Automated verification:

- Debug arm64 build passed.
- 191 unit tests passed with 0 failures and 0 skips.
- 3 XCUITest passed with 0 failures and 0 skips after macOS Automation Mode
  was re-authorized with user authentication.
- Release arm64 build passed.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed.
- `scripts/ghostty/test-verification.sh` passed its happy path and all four
  corruption cases.
- `scripts/phase0/check-boundaries.sh` passed with the canonical sibling
  `grok-build` checkout supplied through `GROK_BUILD_ROOT`.
- `scripts/release/verify-app.sh` passed for the exact Release bundle.
- `scripts/release/security-scan.sh` found no secrets or private local paths
  in Git history, the publishable source snapshot, or the Release bundle.
- `git diff --check` passed.

Final Xcode result bundles:

```text
.build/DerivedDataReleaseValidation/Logs/Test/Test-Coinor-2026.08.08_00-15-28--0300.xcresult
.build/DerivedDataReleaseValidation/Logs/Test/Test-Coinor-2026.08.08_00-24-25--0300.xcresult
```

Manual verification used the real Debug application, embedded Ghostty, and
the real custom Grok binary:

- The startup view showed Conan Code branding, the friendly Conan ASCII
  portrait, live diagnostics, elapsed time, and failure recovery controls.
- Project and conversation rows activated from their full width while pin,
  archive, disclosure, and project actions remained independently clickable.
- Sidebar scrolling and hover transitions remained stable across a populated
  catalog.
- Creating three temporary shell tabs showed one crisp tab strip with no
  reflected duplicate above it.
- Before resizing the sidebar, all six retained PTYs reported `58x182`.
  After resizing, only the visible PTY changed to `58x163`; five hidden PTYs
  remained `58x182`.

Release artifact:

| Field | Final value |
| --- | --- |
| Display name | `Conan Code` |
| Bundle | `Coinor.app` |
| Bundle identifier | `dev.coinor.Coinor` |
| Version | `0.3.1` build `5` |
| Architecture | `arm64` |
| Minimum macOS | `13.0` |
| Signature | Ad-hoc, deep strict verification passed |
| App Sandbox | Disabled |
| `get-task-allow` | Absent |
| Archive | `Artifacts/Coinor-0.3.1-arm64.zip` |
| Archive SHA-256 | `a108f88c0699647a95edadf504f11896774acfc105fedd973f967937cf3115f0` |

## v0.3.0 Terminal-Tab Release Verification

Conversation terminal-tab support was rebased onto `origin/main` at
`f597828`, prepared as Coinor `0.3.0` build `4`, and validated on August 8,
2026. This evidence applies to the `v0.3.0` release source and application
bundle.

Automated verification:

- Full Debug suite:
  `xcodebuild -quiet -project Coinor.xcodeproj -scheme Coinor
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath .build/DerivedData test`
  passed 188 tests with 0 failures and 0 skips.
- Release build passed for Apple Silicon.
- `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` passed.
- `scripts/ghostty/test-verification.sh` passed its happy path and all four
  corruption cases.
- `scripts/phase0/check-boundaries.sh` passed against the recorded
  `grok-build` baseline.
- `scripts/release/verify-app.sh` passed for the Release bundle.
- `scripts/release/security-scan.sh` found no leaks.
- `git diff --check` passed.

Manual verification used the real Debug application, embedded Ghostty, the
real custom Grok binary, and an isolated application-support directory:

- New conversations exposed one permanent `main` tab.
- The `+` button and `Command-T` created independent shells in the exact
  conversation checkout without an explicit command.
- Hidden shells retained scrollback and completed background commands while
  another tab or conversation was selected.
- `Command-1` through `Command-9`, `Command-W`, Ghostty previous/next,
  Ghostty close-tab, Ghostty move-tab, and Ghostty rename-tab actions all
  mapped to Coinor tabs.
- `exit`, the close button, and `Command-W` closed shell tabs and selected the
  left neighbor; `Command-W` on `main` was a no-op.
- Double-click rename committed on Return and blur, cancelled on Escape,
  restored terminal focus, and preserved exact duplicate names.
- Names, order, selected tab, and the monotonic tab counter survived relaunch;
  shell processes were recreated in the correct checkout.
- Twenty simultaneous tabs exercised horizontal overflow and automatic
  selected-tab scrolling without overlap.
- Archiving removed the conversation from the sidebar while its selected
  shell remained alive; unarchiving restored the row and runtime.
- A historical session whose checkout no longer exists showed the inline
  missing-working-directory error with the exact path.
- Right-clicking a tab did not open a tab context menu.

## Environment

| Field | Final value |
| --- | --- |
| Host | macOS 26.5.1 (25F80) |
| CPU | Apple Silicon (`arm64`) |
| Minimum supported macOS | 13.0 |
| Xcode | 26.2 (17C52) |
| Swift | 6.2.3 toolchain, Swift 6 language mode |
| Zig | System 0.16.0; Ghostty build pinned to 0.15.2 |
| Grok binary | `grok 0.2.117-overlay.2 (7e63adf)` |
| Grok source worktree | `e9411ed`; the later commit changes delivery documentation only |
| Grok executable | `~/bin/grok`, resolved to an absolute path |
| Grok leader | Coinor-private socket, no global `use_leader` |
| Ghostty | v1.3.1, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Distribution | Apple Silicon, local ad-hoc signature, not notarized, no App Sandbox |

Developer Tools access was initially disabled on the host. After explicit user
authorization it was enabled with `DevToolsSecurity`, allowing the required
XCTest and XCUITest runner to execute normally.

## Automated Verification

All commands below were run against the final source candidate on August 8,
2026.

| Check | Command | Final result |
| --- | --- | --- |
| Ghostty artifact | `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` | Pass. Verified tag, exact commit, header, static library, full XCFramework, resources, terminfo, and crash reporting disabled. |
| Ghostty corruption suite | `scripts/ghostty/test-verification.sh` | Pass. Happy path plus header, framework, resources, and manifest corruption were all detected. |
| Debug build | `xcodebuild -project Coinor.xcodeproj -scheme Coinor -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData build` | `BUILD SUCCEEDED`. |
| Debug tests | `xcodebuild -quiet -project Coinor.xcodeproj -scheme Coinor -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test` | `TEST SUCCEEDED`. 185 unit tests + 3 XCUITest = 188 tests, 0 failures. |
| Release build | `xcodebuild -project Coinor.xcodeproj -scheme Coinor -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData build` | `BUILD SUCCEEDED`. |
| Release bundle contract | `scripts/release/verify-app.sh .build/DerivedData/Build/Products/Release/Coinor.app` | Pass. Bundle ID, version, arm64 architecture, macOS 13 minimum, strict signature, Ghostty provenance, no sandbox, and no `get-task-allow` verified. |
| Public release security | `scripts/release/security-scan.sh .build/DerivedData/Build/Products/Release/Coinor.app` | Pass. Git history, the exact publishable snapshot, and every regular file in the release bundle were free of detected secrets and the local home path. |
| Native subagent lifecycle | ACP parsing, persisted recursive replay, lifecycle state tests, and real installed-app run | Pass. No hook registration, relay executable, or lifecycle socket is present. |
| Grok binary/source boundary | `~/bin/grok --version`, runtime Git `HEAD`, and clean status | Pass. Installed binary remains release `overlay.2`; source `e9411ed` adds documentation only, so no Grok binary release was produced. |
| Repository boundaries | `scripts/phase0/check-boundaries.sh` | Pass. Grok source and global config boundaries remained intact. |
| English-owned UI scan | `rg` scan across Coinor-owned Swift UI source | Pass. No Spanish Coinor-owned UI literals found. |
| Whitespace errors | `git diff --check` | Pass. |

The terminal-tab candidate's first complete run exposed a transient UI-test
race while startup diagnostics were disappearing. The assertion was changed
to wait for nonexistence, then the complete combined suite passed.

The final Xcode result bundle is:

```text
.build/DerivedData/Logs/Test/Test-Coinor-2026.08.07_22-27-56--0300.xcresult
```

## Manual End-To-End Verification

The real Debug application at
`.build/DerivedData/Build/Products/Debug/Coinor.app` was exercised through
Computer Use with embedded Ghostty and the real custom Grok binary.

| Workflow | Final evidence | Status |
| --- | --- | --- |
| Persisted catalog and transcript restore | Relaunch selected the exact last-visible Grok session and replayed its transcript without a blank shell or manual resume command. | Pass |
| Immediate selection and quit | A different conversation was selected and Coinor was quit immediately. `metadata.json` contained the new session ID before process exit. | Pass |
| Private leader ownership | Normal quit terminated Coinor, root and child clients, and the private leader, then removed its socket and lock. | Pass |
| Stale leader recovery | XCUITest intentionally left a live detached private leader. A later Coinor launch reattached successfully, restored the session, and a clean quit removed that leader. | Pass |
| Single instance | A direct second executable remained outside the runtime: private leader PID and client count were unchanged. LaunchServices also has `LSMultipleInstancesProhibited=true`. | Pass |
| Main-checkout creation | A real conversation was created in the primary checkout and resumed durably. | Pass |
| Remote-default worktree | A named worktree used the fetched remote default branch, remained flat under the original project, and did not mutate the primary checkout. | Pass |
| Local-HEAD fallback | A repository without a usable remote used exact local `HEAD`, displayed a non-blocking English warning, and left the primary checkout unchanged. | Pass |
| Rename, pin, and archive | Conversation rename, project display rename, project icon selection, pin/unpin, and conversation/project archive/unarchive were exercised through the real UI. Pinned rows were not duplicated under projects. | Pass |
| Sidebar controls | Each project keeps a fixed action slot, while `+` appears only on hover or keyboard/accessibility focus. Right-click exposes rename, appearance, and archive actions. | Pass |
| Natural sidebar reordering | Real pointer drags lifted project and conversation previews, moved the insertion space before release, persisted project and project-conversation order after relaunch, and used native edge auto-scroll. Dropping outside restored the prior order without changing metadata. The original metadata file was restored byte-for-byte. | Pass |
| Project appearance | The picker exposes 30 renderable SF Symbols and eight adaptive colors, applies only on `Done`, and preserves older icon metadata through compatibility mapping. | Pass |
| Conversation search | Exact, prefix, substring, token, and subsequence ranking were verified, with recency used only inside equal textual quality and archived items excluded. | Pass |
| Grok update advisory | Semantic fork-version comparison, strictly-newer filtering, launch/periodic monitoring, and preservation of the last successful result after network failure were verified. The installed and latest versions were equal during the final run, so no warning was expected. | Pass |
| Terminal mouse and clipboard | Logical-point coordinates, hover entry/exit, ordinary and double clicks, captured drag selection, cancellation releases, context-menu routing, Copy, Paste, and Select All passed focused routing tests and the full suite. | Pass |
| Voice permission declaration | The Release `Info.plist` contains the English microphone purpose string required when Grok Voice first opens CoreAudio. | Pass |
| Native Liquid Glass | On macOS 26, the standard `NavigationSplitView` sidebar refracted a subtle extension of the active terminal. No manual tint or second glass layer remains. | Pass |
| Active archive continuity | Archiving a working root hid it without killing root or child processes. Unarchiving before idle preserved the same PIDs and final response. | Pass |
| Simultaneous descendants | Three native subagents ran concurrently. One spawned a nested native subagent. All descendants appeared flat in the right column while the root retained the left 50 percent. | Pass |
| Native lifecycle without hook noise | With `~/.grok/hooks` empty, a 20-second native subagent opened an interactive right pane, returned `NATIVE-PANEL-LIVE-OK`, closed its pane, and restored the root to full width. Neither that run nor the preceding `NATIVE-ACP-NO-HOOKS-OK` run emitted a new `[hooks: ...]` row. | Pass |
| Pane cleanup | A and C closed independently, the nested pane closed, then B closed. The root reclaimed 100 percent after the last descendant ended. | Pass |
| Heavy panel transcript | The durable outputs were `A-FINAL`, `B-FINAL`, `C-FINAL`, `NESTED-FINAL`, and final root response `COINOR-FINAL-PANELS-OK`. | Pass |
| Needs-input routing | A real Grok `ask_user` interaction changed the project and root row to `Needs attention`, showed the orange attention indicator, accepted a fully interactive answer, and returned `COINOR-ATTENTION-OK`. | Pass |
| Notification authorization | The first attention state registers Coinor with macOS Notifications even when Coinor is focused. macOS notification permission was enabled for Coinor and the background needs-input path was repeated. | Pass with capture limitation |
| Sustained multi-pane behavior | The nested run remained active for 141 seconds. Observed Grok client RSS stayed roughly 34-65 MB per client, panes remained nonblank, and no process or surface runaway was observed. | Pass |

The global notification banner is a system overlay outside the application
window. The available Computer Use screenshots are app-scoped, so they cannot
capture that overlay. Automated tests verify the real request body, identifier,
authorization behavior, and focused suppression; System Settings confirmed
that Coinor was registered and notifications were enabled.

## Visual Evidence

The final 0.2.1 Release candidate was opened from
`.build/DerivedData/Build/Products/Release/Coinor.app` and inspected at
1704 x 1059 logical window size. The capture was intentionally not committed
because it displayed the owner's live Grok transcript. Search, Pinned, project
rows, terminal content, and input remained readable with no overlap. The
catalog and exact last-visible Grok session restored normally. Expanded and
collapsed project headers shared the same horizontal alignment.

| Screenshot | Captured state | Review |
| --- | --- | --- |
| `docs/screenshots/compact.png` (840 x 572) | Root plus three concurrent descendant panes. | Pass. Root occupies the left half; three equal-height panes occupy the right half; no overlap or blank surface. |
| `docs/screenshots/standard.png` (1074 x 534) | Root-only layout after descendants completed. | Pass. Root reclaimed the terminal region and sidebar actions remained readable. |
| `docs/screenshots/wide.png` (1225 x 768) | Full-screen root plus a nested descendant. | Pass. Fixed 50/50 split, readable terminal content, and no Ghostty window/tab/split chrome. |

The Computer Use service returns logical-resolution captures. The wide capture
was taken full-screen on a 3456 x 2234 Retina display.

## Remaining Risks

- Physical movement between mixed-scale Retina displays and a physical
  sleep/wake cycle were not induced during the final pass. Phase 0 covered
  backing-scale callbacks, occlusion, wake callbacks, resize, and repeated
  mount/unmount.
- Automatic relinking after a repository directory is moved is not a product
  contract. The user can add the checkout again; independent clones remain
  intentionally distinct.
- The build is ad-hoc signed and not notarized. It is intended for this local
  Apple Silicon Mac, not third-party distribution.

## Commit Record

| Scope | Commit |
| --- | --- |
| Repository initialization | `04a6982` |
| Phase 0 integration gate | `c69a264` |
| Phases 1-6 native product implementation | `a2c5551` |
| Notification authorization QA fix | `b2fe81d` |
| Phase 7 quality, packaging, and documentation | `c43c1f8` |

## v0.3.0 Final Boundary Record

| Field | Final value |
| --- | --- |
| Debug build | Pass |
| Debug tests | 188 tests, 0 failures, 0 skips |
| Release build | Pass |
| Release verifier | Pass |
| Release version | `0.3.0` build `4` |
| Conversation terminal-tab QA | Pass |
| Screenshots | Compact, standard, and wide reviewed |
| Final `grok-build` status | Exactly matches the Phase 0 baseline shown below |
| Final `~/.grok/config.toml` SHA-256 | `ee006941501e78d4002495c0e799bbdd74d025555aa0e57d722ec15dc4e9fb86` |

Required preserved `grok-build` status:

```text
 M overlay/hooks/herdr-subagent-pane.sh
?? CONTEXT.md
?? docs/
?? overlay/tests/fixtures/
?? overlay/tests/model_matrix.py
```
