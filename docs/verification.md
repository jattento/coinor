# Coinor Verification Record

Date: August 8, 2026

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
