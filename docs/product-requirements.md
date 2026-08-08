# Product requirements

## Interface language

All Coinor-owned user interface copy is always written in English. This
includes navigation labels, menus, buttons, tooltips, dialogs, empty states,
warnings, and errors.

## Projects and conversations

Coinor discovers projects from Grok's persisted conversations and groups them
by local Git repository. A repository's main checkout and all of its worktrees
form one project. Independent clones remain separate projects even when they
share a remote URL.

Projects with no Grok conversations can be added manually. Conversations
appear in one flat list beneath their project; worktree conversations do not
create a second navigation level or display a worktree badge in the sidebar.

Coinor can assign a local display name, icon, and icon color to a project from
its sidebar context menu. The appearance picker offers the complete Coinor
catalog of 30 project symbols and eight adaptive system colors. These
presentation overrides do not rename, move, or otherwise modify the
underlying repository.

## Sidebar presentation

Sidebar controls use adaptive system colors so icons remain visible in both
Light and Dark appearances. Project and conversation rows use a lighter system
font weight than terminal content.

The new-conversation `+` control is visible only while its project row is
hovered or the control has keyboard or accessibility focus. Its reserved layout
space remains stable so rows do not move when it appears.

On macOS 26 or newer, Coinor uses the native Liquid Glass sidebar supplied by
`NavigationSplitView` and subtly extends terminal content beneath it with
`backgroundExtensionEffect()`. Coinor does not add a second glass layer, tint,
or opaque background. Earlier macOS versions retain the standard system
sidebar presentation.

## Conversation organization

Coinor can pin and unpin conversations. Pinned conversations appear in a
top-level `Pinned` section above `Projects` and are not duplicated beneath
their project. Unpinning returns a conversation to its project.

Coinor can archive and unarchive individual conversations and complete
projects. Pinning and archiving affect only Coinor's local organization
metadata; they do not modify or delete the underlying Grok sessions.

Archiving a running conversation removes it from the normal sidebar without
interrupting its current work. Coinor unloads the live session after it becomes
inactive.

Archived conversations and projects are managed from a dedicated view opened
from the sidebar. Archived items are not rendered as a permanent sidebar
section.

Coinor can rename conversations from the sidebar. Renaming updates the
underlying Grok session through Grok's session administration API; Coinor does
not store a separate display-title alias.

Projects, pinned conversations, and the conversations within each project can
be dragged to user-defined orders. Each drag lifts a visible preview with the
row's real content, moves that preview with the pointer, and opens an animated
space between candidate neighbors before the user releases it. Releasing
outside a valid destination cancels the preview without changing stored order.
Holding near the top or bottom edge uses the sidebar's native auto-scroll.

Orders are local Coinor metadata and survive relaunch. Project ordering
preserves the relative slot of an archived project. Project conversation
ordering preserves the slots of pinned and archived conversations so unpinning
or unarchiving returns them where the user left them. Pinned conversations can
be reordered only within `Pinned`, and project conversations can be reordered
only within their current project. Search results are not draggable.

Reordering must not introduce an additional outline level: every project header
remains aligned in the same flat column, whether collapsed, expanded, or moved
past a project with conversations.

A fuzzy conversation search field appears above `Pinned`. While an effective
query is present, the sidebar shows one flat result list rather than duplicating
the normal sections. Textual closeness is the primary ranking signal; more
recent activity breaks ties, and archived conversations or projects never
appear.

## Creating conversations

The add button on a project opens a compact menu with two actions:

- `In Main Checkout`
- `In New Worktree`

Choosing `In New Worktree` opens a dialog requiring a worktree name. Before
creating it, Coinor fetches the remote and bases the worktree on the remote's
default branch. If the fetch or remote resolution fails, Coinor creates the
worktree from the local `HEAD` and shows a non-blocking warning.

## Conversation lifetime

Every conversation opened during the current Coinor run remains live while
the application is open, even when another conversation is selected. Switching
the sidebar selection changes only which conversation is visible.

## Relaunch behavior

Coinor restores the last visible conversation when the application launches.
Other conversations remain listed and are resumed lazily when selected. A
resumed conversation opens directly through `grok --resume`; Coinor never
shows a blank shell that requires the user to issue the resume command.

Coinor does not guarantee that conversations continue working after the
application quits.

## Window and pane layout

Coinor uses one main macOS window. The selected conversation's root terminal
uses the full content area while no subagent is active. As soon as a subagent
starts, the root terminal keeps the left 50 percent and all active subagent
terminals divide the right 50 percent vertically.

Every root and subagent pane is a fully interactive Grok terminal. Nested
subagents appear at the same visual level as direct subagents, ordered by start
time. A subagent pane opens when the subagent starts and closes when it ends.

## Terminal configuration

Every terminal pane loads the user's standard Ghostty configuration, including
fonts, colors, and terminal behavior. Coinor overrides only the values required
to launch the correct Grok session in the correct working directory through
Coinor's isolated leader, plus the mouse-capture setting required for native
text selection.

Mouse coordinates, hover, clicks, double clicks, and drag selection remain
fully interactive inside Grok. A normal drag selects terminal text even while
Grok has mouse reporting enabled; normal clicks and double clicks continue to
activate Grok rows and expandable task output. Selected text can be copied with
the standard macOS command or the terminal context menu.

Voice uses Grok's native microphone capture. Coinor declares the macOS
microphone purpose string, and macOS requests access when the user starts
Voice; Coinor does not record or persist audio itself.

## Activity and attention

A working conversation shows a spinner in the sidebar. A conversation that
needs user input shows an attention indicator, which takes priority over the
working spinner. Subagent activity and attention propagate to the root
conversation and its project. Opening a conversation that needs attention
focuses the pane requesting input.

Coinor sends a native macOS notification when a conversation needs attention
only while Coinor is not the focused application.

## Grok compatibility updates

Coinor checks the public latest release of the configured Grok fork at launch
and periodically while open. When that release is newer than the installed
binary, an orange warning appears at the right edge of the window toolbar and
opens the matching release page. Network and version-probe failures are
non-blocking and preserve the last successful update state.
