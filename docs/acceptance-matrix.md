# Coinor Acceptance Matrix

Date: August 7, 2026

Status terms:

- **Pass**: implementation and final evidence exist.
- **Phase 0 pass**: durable spike evidence is recorded in
  `docs/phase-0-results.md`.
- **Hardware residual**: implementation and synthetic coverage pass, but the
  named physical hardware event was not induced.

## Product Requirements

| Section | Requirement | Source and automated evidence | Final manual evidence | Status |
| --- | --- | --- | --- | --- |
| 1. Interface language | Every Coinor-owned label, menu, tooltip, warning, empty state, diagnostic, and notification is English. | `Coinor/Features/AppShell`, `AttentionNotificationService.swift`, `AppFoundationTests`, notification tests, final Swift literal scan. | Sidebar, dialogs, warnings, archived view, activity text, and error states were reviewed. Grok-rendered content is outside Coinor-owned copy. | Pass |
| 2. Projects and conversations | List persisted Grok sessions; group main checkout and worktrees by canonical Git project; keep clones separate; retain manually added empty projects; keep conversations flat. | `GrokControlClient`, `GitProjectResolver`, `SessionCatalog`; catalog pagination/malformed payload tests; resolver and catalog tests. | Real main, linked worktree, Grok worktree, and independent project rows were inspected in the sidebar. | Pass |
| 3. Conversation organization | Pin/unpin, dedicated archives, metadata-only archive, active archive continuity, and Grok-owned rename. | `MetadataModels`, `MetadataStore`, `SessionCatalog`, `ArchivedItemsView`, `ConversationRuntimeManager`, `GrokControlClient.rename`; metadata/catalog/runtime tests. | Rename, pin/unpin, conversation/project archive/unarchive, idle unload, and active archive continuity were exercised. | Pass |
| 4. Creating conversations | `In Main Checkout`, named `In New Worktree`, remote default branch, exact local-HEAD fallback, and English warning. | `AppShellSidebar`, `AppCoordinator`, `WorktreeService`; 8 Git fixture tests. | Remote-default and no-remote fallback workflows completed without mutating the primary checkout. | Pass |
| 5. Conversation lifetime | Activated roots remain live while Coinor is open; changing visible rows does not stop work. | `ConversationRuntimeManager`, `RuntimeHostView`, runtime tests. | Root and child PIDs stayed stable through selection changes and active archive/unarchive. | Pass |
| 6. Relaunch behavior | Restore only the last visible session, exact resume, lazy resume for other rows, no blank shell, no promise after quit. | `AppCoordinator.start`, `TerminalLaunchRequest`, `MetadataStoreTests.relaunchRestoresPersistedState`. | Immediate selection-and-quit persisted the new session. Relaunch restored its transcript directly. | Pass |
| 7. Window and pane layout | One window; root 100 percent without descendants; fixed 50/50 with descendants; flat equal-height right column; every pane interactive. | `ConversationPaneView`, `RuntimeHostView`, `ConversationRuntimeManager`, lifecycle ordering/reconciliation tests. | Three concurrent descendants plus one nested descendant were visible and interactive. Panes closed independently and root reclaimed full width. | Pass |
| 8. Terminal configuration | Load standard Ghostty config; Coinor owns launch overrides and blocks external windows/tabs/splits. | `GhosttyConfiguration`, `GhosttyRuntime`, `GhosttySurfaceView`, Ghostty Phase 0 spike and artifact verification. | Real embedded terminals rendered nonblank without `/Applications/Ghostty.app`; no external Ghostty UI appeared. | Pass |
| 9. Activity and attention | Working and needs-input aggregation, correct pane focus, root/project propagation, and unfocused native notifications. | Activity models, `AppCoordinator`, `TerminalSessionFocus`, `AttentionNotificationService`; activity/focus/notification tests. | Working and orange needs-attention states were observed with a real interactive `ask_user`; macOS registered Coinor and notifications were enabled. | Pass |

## Phase 0: Integration Gate

### Ghostty Spike

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Nonblank surface at desktop and compact sizes | `Spikes/GhosttySpike/test.sh`, image probe, spike screenshots | Phase 0 pass |
| Keyboard and resize do not recreate or shift the surface | `exercise.sh` lifecycle counters and input checks | Phase 0 pass |
| Surface recreation is clean | Four creates matched four destroys; no visible child remained | Phase 0 pass |
| No installed Ghostty application is required | Minimal-environment and dependency checks | Phase 0 pass |
| Finder/minimal-environment launch works | `minimal-environment.sh` | Phase 0 pass |
| Occlusion, callbacks, and repeated mounts are stable | Phase 0 exercise | Phase 0 pass |
| Physical mixed-scale movement and physical sleep/wake | Backing-scale, occlusion, and wake paths covered; physical event not induced | Hardware residual |
| Ghostty shortcuts cannot escape Coinor | Unsupported window/tab/split actions suppressed | Phase 0 pass |

### Grok Shared-Session Spike

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Root and observer render the same live turn | `python3 Spikes/GrokSharedSession/run_spike.py` | Phase 0 pass |
| Observer does not steal or duplicate execution | Driver-only reverse-request counts | Phase 0 pass |
| Hidden subagent loads by explicit ID | Native hidden child exact resume | Phase 0 pass |
| No Herdr or global `use_leader` | Isolated child environment and private leader | Phase 0 pass |

### Hook Spike

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Real start reaches listener | `Spikes/HookSpike/RESULTS.md` | Phase 0 pass |
| Stop closes pane state | Hook spike and production lifecycle tests | Phase 0 pass |
| Abrupt root death clears descendants | Real `SIGKILL` plus root-death test | Phase 0 pass |
| Cancellation closes without `SubagentStop` | Real cancellation plus persisted-cancellation test | Phase 0 pass |
| Relay remains fail-open and fast | No-listener, malformed input, detached process group, and delivery failure tests | Phase 0 pass |

## Phase 1: Foundation

| Acceptance item | Evidence | Status |
| --- | --- | --- |
| Standalone native SwiftUI/AppKit macOS repository | `Coinor.xcodeproj`, `Coinor`, `CoinorTests`, `CoinorUITests` | Pass |
| One app target, one bundled hook relay, unit and UI tests | Xcode project and `Tools/CoinorHookRelay` | Pass |
| Pinned Ghostty and non-sandboxed profile | `scripts/ghostty`, entitlements, release verifier | Pass |
| English window, startup diagnostics, sidebar, terminal region | App shell source and 3 XCUITests | Pass |

## Phase 2: Grok Control Plane And Catalog

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| All persisted sessions appear with paginated deduplication | `GrokControlClientTests` catalog fixtures and real sidebar | Pass |
| Main and worktree sessions group together | Resolver tests and real worktree QA | Pass |
| Independent clones remain separate | `testIndependentCloneHasDistinctIdentityEvenWithSameSource` | Pass |
| Conversations stay flat | `sessionsSharingAProjectIdentityStayFlatRegardlessOfOrigin` | Pass |
| Activity changes update live | Roster broadcasts, activity tests, real working/attention indicators | Pass |
| Malformed catalogs fail loudly | Missing/wrong `sessions`, invalid cursor, duplicate roster tests | Pass |

## Phase 3: Root Terminal Runtimes

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Dormant conversation opens at existing Grok state | Exact resume launch plus real transcript restore | Pass |
| No blank shell | Real launch and relaunch screenshots | Pass |
| Switching rows keeps work alive | Runtime retention and PID continuity QA | Pass |
| Only last visible session auto-resumes | Metadata test and immediate selection/quit/relaunch QA | Pass |
| Normal shutdown owns clients and private leader | Deferred AppKit termination plus real process cleanup | Pass |
| Stale private leader recovers | XCUITest orphan leader reattached and later cleaned | Pass |
| Concurrent instance does not steal resources | Application lock, plist prohibition, tests, and direct second-process QA | Pass |

## Phase 4: Subagent Panes

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| First child changes root to left 50 percent | `ConversationPaneView`, compact/wide screenshots | Pass |
| Every active descendant is visible on the right | Three-descendant live screenshot | Pass |
| Every pane accepts input | Real Ghostty child resumes and interactive QA | Pass |
| Nested descendants remain flat in start order | Lifecycle tests and nested live run | Pass |
| Root reclaims full width | Live child cleanup and standard screenshot | Pass |
| Cancellation, reordering, missed stop, and abrupt root death leave no stale panes | Lifecycle suite and Phase 0 real cancellation/root death | Pass |
| No Herdr process or UI | Source/runtime scan and native Coinor pane implementation | Pass |

## Phase 5: Creation And Worktrees

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Main-checkout creation starts in primary checkout | Creation UI and real run | Pass |
| Remote default branch is fetched and used | `testRemoteDefaultBranchIsFetchedAndUsedWithoutMutatingPrimaryCheckout` plus real run | Pass |
| Fetch failure uses exact local `HEAD` | No-remote, fetch-failure, and detached-HEAD tests plus real run | Pass |
| Warning is visible and non-blocking | `WorktreeService` and real warning banner | Pass |
| Worktree conversation remains flat under original project | Resolver/catalog tests and real sidebar | Pass |

## Phase 6: Organization And Attention

| Acceptance criterion | Evidence | Status |
| --- | --- | --- |
| Pin, archive, and project registration survive relaunch | Atomic metadata tests and real relaunch QA | Pass |
| Rename is stored by Grok, not a Coinor alias | ACP rename test and real rename | Pass |
| Archive never deletes Grok session | Metadata-only model and unarchive/resume QA | Pass |
| Active archive does not interrupt work | Stable root/child PIDs and final response | Pass |
| Attention reaches root/project and correct terminal | Activity/focus tests and real `ask_user` | Pass |
| Notification permission is prepared before background delivery | Focused authorization test, macOS registration, and enabled Coinor notification settings | Pass |

## Phase 7: Quality And Packaging

### Validation

| Validation item | Evidence | Status |
| --- | --- | --- |
| Compact, standard, and wide layouts | `docs/screenshots/compact.png`, `standard.png`, `wide.png` | Pass |
| Multiple simultaneous descendants including nested work | 141-second real run and durable Grok outputs | Pass |
| Terminal memory and GPU behavior | Nonblank sustained panes; observed Grok client RSS roughly 34-65 MB | Pass |
| Relaunch during normal and needs-input work | Exact restore, attention runs, and stale leader recovery | Pass |
| Stale hook socket and crashed leader recovery | Listener ownership plus real orphan leader reattach/cleanup | Pass |
| Ghostty config/resource mismatch | Runtime diagnostics plus corruption suite | Pass |
| Missing or incompatible Grok | Startup diagnostics, version timeout, protocol, and extension tests | Pass |
| No remote, several remotes, detached HEAD | Git fixture integration suite | Pass |
| Moved repository directory | Manual re-add is supported; automatic relinking is not a product contract | Documented limitation |

### Packaging

| Packaging item | Evidence | Status |
| --- | --- | --- |
| Arm64 Coinor application bundle | Debug and Release builds | Pass |
| Pinned static Ghostty unit | Manifest and release verifier | Pass |
| Bundled and installed hook relay | Package tests plus Debug/Release install/verify | Pass |
| Install/repair command | `scripts/hooks/install.sh`, ownership refusal, `verify.sh` | Pass |
| Release instructions and licensing | `README.md`, `docs/release.md`, bundled MIT notice | Pass |

## V1 Definition Of Done

| Outcome | Status |
| --- | --- |
| Standalone native macOS app with no Herdr or Paseo dependency | Pass |
| Organizes durable Grok conversations by local project | Pass |
| Creates main-checkout and named-worktree conversations | Pass |
| Resumes exact sessions without manual terminal commands | Pass |
| Keeps hidden conversations working while Coinor remains open | Pass |
| Shows root and all active descendants in the agreed interactive layout | Pass |
| Pin, archive, rename, attention, and English-only behavior match requirements | Pass |
| Unsupported Grok or Ghostty integration is reported clearly | Pass |

## Screenshot Evidence

- `docs/screenshots/compact.png`: three active descendants in the right half.
- `docs/screenshots/standard.png`: root-only terminal after cleanup.
- `docs/screenshots/wide.png`: full-screen 50/50 root and nested descendant.

Exact dimensions and visual review notes are recorded in
`docs/verification.md`.
