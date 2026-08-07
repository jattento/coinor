# Coinor Verification Record

Date: August 7, 2026

## Environment

| Field | Final value |
| --- | --- |
| Host | macOS 26.5.1 (25F80) |
| CPU | Apple Silicon (`arm64`) |
| Minimum supported macOS | 13.0 |
| Xcode | 26.2 (17C52) |
| Swift | 6.2.3 toolchain, Swift 6 language mode |
| Zig | 0.16.0 |
| Grok | `grok 0.2.117 (29189e7)` |
| Grok executable | `~/bin/grok`, resolved to an absolute path |
| Grok leader | Coinor-private socket, no global `use_leader` |
| Ghostty | v1.3.1, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Distribution | Apple Silicon, local ad-hoc signature, not notarized, no App Sandbox |

Developer Tools access was initially disabled on the host. After explicit user
authorization it was enabled with `DevToolsSecurity`, allowing the required
XCTest and XCUITest runner to execute normally.

## Automated Verification

All commands below were run against the final source candidate on August 7,
2026.

| Check | Command | Final result |
| --- | --- | --- |
| Ghostty artifact | `scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty` | Pass. Verified tag, exact commit, header, static library, full XCFramework, resources, terminfo, and crash reporting disabled. |
| Ghostty corruption suite | `scripts/ghostty/test-verification.sh` | Pass. Happy path plus header, framework, resources, and manifest corruption were all detected. |
| Hook relay package | `swift test --package-path Tools/CoinorHookRelay` | Pass. 4 tests, 0 failures. |
| Debug build | `xcodebuild -project Coinor.xcodeproj -scheme Coinor -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData build` | `BUILD SUCCEEDED`. |
| Full Debug test | `xcodebuild -project Coinor.xcodeproj -scheme Coinor -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test` | `TEST SUCCEEDED`. 35 XCTest + 95 Swift Testing + 3 XCUITest = 133 tests, 0 failures. |
| Release build | `xcodebuild -project Coinor.xcodeproj -scheme Coinor -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData build` | `BUILD SUCCEEDED`. |
| Release bundle contract | `scripts/release/verify-app.sh .build/DerivedData/Build/Products/Release/Coinor.app` | Pass. Bundle ID, version, arm64 architecture, macOS 13 minimum, strict signature, Ghostty provenance, no sandbox, and no `get-task-allow` verified. |
| Hook install and repair | `scripts/hooks/install.sh <Debug-or-Release-Coinor.app>` | Pass for the exact Debug and Release bundles. |
| Hook installation contract | `scripts/hooks/verify.sh <Debug-or-Release-Coinor.app>` | Pass for the exact Debug and Release bundles. |
| Repository boundaries | `scripts/phase0/check-boundaries.sh` | Pass. Grok source and global config boundaries remained intact. |
| English-owned UI scan | `rg` scan across `Coinor`, `CoinorTests`, and `CoinorUITests` | Pass. No Spanish Coinor-owned UI literals found. |
| Whitespace errors | `git diff --check` | Pass. |

The final Xcode result bundle is:

```text
.build/DerivedData/Logs/Test/Test-Coinor-2026.08.07_09-47-04--0300.xcresult
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
| Single instance | A direct second executable remained outside the runtime: private leader PID, hook socket inode, and client count were unchanged. LaunchServices also has `LSMultipleInstancesProhibited=true`. | Pass |
| Main-checkout creation | A real conversation was created in the primary checkout and resumed durably. | Pass |
| Remote-default worktree | A named worktree used the fetched remote default branch, remained flat under the original project, and did not mutate the primary checkout. | Pass |
| Local-HEAD fallback | A repository without a usable remote used exact local `HEAD`, displayed a non-blocking English warning, and left the primary checkout unchanged. | Pass |
| Rename, pin, and archive | Rename, pin, unpin, conversation archive/unarchive, and project archive/unarchive were exercised through the real UI. Pinned rows were not duplicated under projects. | Pass |
| Active archive continuity | Archiving a working root hid it without killing root or child processes. Unarchiving before idle preserved the same PIDs and final response. | Pass |
| Simultaneous descendants | Three native subagents ran concurrently. One spawned a nested native subagent. All descendants appeared flat in the right column while the root retained the left 50 percent. | Pass |
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

## Final Boundary Record

| Field | Final value |
| --- | --- |
| Debug build | Pass |
| Full Debug test | 133 tests, 0 failures |
| Release build | Pass |
| Release verifier | Pass |
| Screenshots | Compact, standard, and wide reviewed |
| Final `grok-build` status | Exactly matches the Phase 0 baseline shown below |
| Final `~/.grok/config.toml` SHA-256 | `a33ab461777d94cd9a5d40f2fc1c0323adbd11b2bd5f89a29e228fbe51c77300` |

Required preserved `grok-build` status:

```text
 M overlay/hooks/herdr-subagent-pane.sh
?? CONTEXT.md
?? docs/
?? overlay/tests/fixtures/
?? overlay/tests/model_matrix.py
```
