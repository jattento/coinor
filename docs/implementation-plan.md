# Coinor implementation plan

## Delivery strategy

Build Coinor as a sequence of vertical slices. The first slice proves the
unstable integrations before significant application UI is written. Later
slices add behavior without replacing the runtime boundaries established by
the prototype.

## Phase 0: integration spikes

### Ghostty spike

Build a minimal macOS app that:

- links a pinned `GhosttyKit.xcframework`
- bundles the matching Ghostty resources and terminfo
- renders one AppKit-backed Ghostty surface inside SwiftUI
- loads the user's default Ghostty configuration
- runs an absolute executable path in an explicit working directory
- supports keyboard input, selection, scrolling, resizing, and clean teardown
- handles clipboard, URL, close-request, and unsupported window/tab/split actions

Acceptance criteria:

- the surface is nonblank on launch
- terminal content fills the expected bounds at desktop and compact sizes
- keyboard and resize events do not shift or recreate the surface
- closing and recreating the surface does not crash or leak a visible process
- the app runs without an installed Ghostty application
- the app launches from Finder with a minimal environment
- Retina movement, occlusion, sleep/wake, and repeated mount/unmount are stable
- Ghostty keybindings cannot create windows, tabs, or splits outside Coinor

### Grok shared-session spike

Build a command-line harness that:

- starts `grok agent --leader` on a private socket
- creates a root session with a client-chosen UUID
- attaches a second Grok TUI to the same session
- verifies replay and live updates
- starts a native subagent and attaches a TUI to its explicit child ID
- verifies the original root remains the driver

Acceptance criteria:

- both clients render the same live turn
- the observer does not duplicate or steal execution
- a hidden subagent session loads by explicit ID
- the test passes without Herdr and without global `use_leader`

### Hook spike

Build the hook relay and a temporary listener that:

- receives `SessionStart`, `SubagentStart`, `SubagentStop`, and `SessionEnd`
- returns fast enough not to stall Grok
- detaches delivery from the hook process group
- preserves parent and child session IDs
- is harmless when no listener exists
- handles duplicate and start/stop-reordered fixtures

Acceptance criteria:

- a real subagent start reaches the listener
- stop closes the corresponding synthetic pane state
- killing the root clears all descendant state
- cancellation closes the pane even when `SubagentStop` is absent
- no hook failure blocks or fails a Grok turn

Phase 0 is the go/no-go gate. Do not build the complete sidebar until all three
spikes pass.

This spike passed and established the lifecycle invariants, but the production
relay was later retired after Grok's native ACP stream was verified to expose
the same subagent lifecycle with replay. The spike remains historical evidence,
not a runtime dependency.

## Phase 1: repository and application foundation

Create the standalone Coinor repository with:

- one macOS SwiftUI application target
- a pinned Ghostty framework build/install script
- a non-sandboxed app entitlement/profile suitable for running local tools
- `App`, `Domain`, `Grok`, `Terminal`, `Persistence`, and `Features` source
  groups without separate packages unless compilation boundaries justify them
- unit and UI test targets
- the context, ADR, product, architecture, and plan documents from this design

Initial application behavior:

- one English-language window
- startup diagnostics for Grok, Ghostty, and the leader socket
- an empty sidebar shell and terminal content region

## Phase 2: Grok control plane and catalog

Implement:

- JSON-RPC framing over the `grok agent stdio` subprocess
- ACP initialize and extension requests
- paginated `x.ai/session/list`
- `x.ai/sessions/list` plus `x.ai/sessions/changed`
- session catalog and activity reconciliation keyed by session ID
- Git common-directory project identity
- main-checkout and worktree resolution
- manually registered empty projects

Acceptance criteria:

- all persisted Grok sessions appear
- main-checkout and worktree sessions group into one project
- independent clones remain separate
- conversations stay flat beneath the project
- activity changes update without restarting Coinor

## Phase 3: root terminal runtimes

Implement:

- `GhosttyRuntime` and `GhosttySurfaceView`
- new-session launch with a Coinor-generated UUID
- exact-session resume
- conversation runtime retention while switching sidebar rows
- last-visible restoration and lazy resume after application relaunch
- runtime shutdown on application exit

Acceptance criteria:

- selecting a dormant conversation opens directly at its existing Grok state
- no blank shell is ever displayed
- switching conversations does not stop in-flight work
- only the last visible conversation auto-resumes after relaunch

## Phase 4: subagent panes

Implement:

- native ACP subagent lifecycle subscription and persisted replay
- parent-to-root descendant mapping
- interactive child terminal launch on the shared leader
- bounded retry for the child-persistence startup race
- fixed 50/50 root/right-column layout
- flat nested-subagent ordering
- immediate stop removal
- duplicate, reorder, cancellation, root-exit, and missed-update reconciliation

Acceptance criteria:

- first subagent changes the root from 100 percent to the left 50 percent
- every active descendant is simultaneously visible on the right
- every pane accepts input
- nested subagents appear flat in start order
- the root reclaims 100 percent after the last child ends
- abrupt root death and cancelled children do not leave stale panes
- no Herdr process or UI is involved

## Phase 5: creation and worktrees

Implement:

- project add popover
- `In Main Checkout`
- `In New Worktree`
- required worktree-name dialog
- remote default-branch discovery
- non-mutating fetch
- remote-base launch and local-HEAD fallback warning

Acceptance criteria:

- local creation starts in the primary checkout
- worktree creation uses the fetched remote default branch when available
- fetch failure still creates the conversation from local `HEAD`
- the fallback warning is visible and non-blocking
- the worktree conversation appears flat under the original project

## Phase 6: organization and attention

Implement:

- versioned atomic metadata store
- `Pinned` above `Projects`
- pin/unpin without duplicate project rows
- project and conversation archive/unarchive
- dedicated archived-items view
- finish-current-work-then-unload archive behavior
- sidebar rename through `x.ai/session/rename`
- activity glyph aggregation
- attention focus routing
- macOS notifications while unfocused

Acceptance criteria:

- pin, archive, and project registration survive relaunch
- Grok titles update outside Coinor after rename
- archive never deletes a Grok session
- archived active work is not interrupted and unloads when inactive
- subagent attention reaches the root row and correct pane

## Phase 7: quality and packaging

Validate:

- layout screenshots at compact, standard, and wide window sizes
- multiple simultaneous conversations and subagents
- terminal memory and GPU behavior
- app relaunch during idle, working, and needs-input states
- native lifecycle replay and crashed leader recovery
- Ghostty configuration errors
- Ghostty resource/header/framework revision mismatch detection
- missing or incompatible Grok binary
- repositories with no remote, several remotes, detached HEAD, and moved paths

Package:

- Coinor application bundle
- pinned static Ghostty framework, header, and matching resources
- local release build and installation instructions

## Test shape

Use focused tests at each boundary:

- pure unit tests for project identity, metadata migrations, state aggregation,
  pane ordering, and worktree fallback decisions
- JSON fixtures for Grok ACP lifecycle payloads
- process integration tests for JSON-RPC framing and native lifecycle replay
- retry tests for a child session whose summary appears after the native start
- Git fixture repositories for worktree grouping and remote fallback
- AppKit tests for surface lifecycle where practical
- Playwright is not applicable to the native UI; use XCTest/XCUITest and
  screenshot inspection

## Definition of done for v1

Coinor v1 is done when:

- it launches as a standalone native macOS app
- it requires neither Herdr nor Paseo
- it lists and organizes all Grok conversations by local project
- it creates main-checkout and named-worktree conversations
- it resumes exact Grok sessions without manual terminal commands
- conversations keep working while hidden inside an open Coinor run
- root and all active subagents are visible and interactive in the agreed layout
- pin, archive, rename, attention, and English-only interface behavior match
  the product requirements
- the app reports unsupported Grok or Ghostty integration clearly
