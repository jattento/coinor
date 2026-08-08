# Coinor Verification Record

Date: August 8, 2026

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
