# Product requirements

## Interface language

The user-visible product name is Conan Code. Coinor remains the internal
repository and compatibility identifier.

All Conan Code-owned user interface copy is always written in English. This
includes navigation labels, menus, buttons, tooltips, dialogs, empty states,
warnings, and errors.

## Projects and conversations

Conan Code discovers projects from Grok's persisted conversations and groups them
by local Git repository. A repository's main checkout and all of its worktrees
form one project. Independent clones remain separate projects even when they
share a remote URL.

Projects with no Grok conversations can be added manually. Conversations
appear in one flat list beneath their project; worktree conversations do not
create a second navigation level or display a worktree badge in the sidebar.

Conan Code can assign a local display name, icon, and icon color to a project from
its sidebar context menu. The appearance picker offers the complete Conan Code
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

On macOS 26 or newer, Conan Code uses the native Liquid Glass sidebar supplied by
`NavigationSplitView` and subtly extends terminal content beneath it with
`backgroundExtensionEffect()`. Conan Code does not add a second glass layer, tint,
or opaque background. Earlier macOS versions retain the standard system
sidebar presentation.

## Conversation organization

Conan Code can pin and unpin conversations. Pinned conversations appear in a
top-level `Pinned` section above `Projects` and are not duplicated beneath
their project. Unpinning returns a conversation to its project.

Conan Code can archive and unarchive individual conversations and complete
projects. Pinning and archiving affect only Conan Code's local organization
metadata; they do not modify or delete the underlying Grok sessions.

Archiving a running conversation removes it from the normal sidebar without
interrupting its current work. Conan Code unloads the live session after it becomes
inactive.

Archived conversations and projects are managed from a dedicated view opened
from the sidebar. Archived items are not rendered as a permanent sidebar
section.

Conan Code can rename conversations from the sidebar. Renaming updates the
underlying Grok session through Grok's session administration API; Conan Code does
not store a separate display-title alias.

Projects, pinned conversations, and the conversations within each project can
be dragged to user-defined orders. Each drag lifts a visible preview with the
row's real content, moves that preview with the pointer, and opens an animated
space between candidate neighbors before the user releases it. Releasing
outside a valid destination cancels the preview without changing stored order.
Holding near the top or bottom edge uses the sidebar's native auto-scroll.

Orders are local Conan Code metadata and survive relaunch. Project ordering
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
creating it, Conan Code fetches the remote and bases the worktree on the remote's
default branch. If the fetch or remote resolution fails, Conan Code creates the
worktree from the local `HEAD` and shows a non-blocking warning.

## Conversation lifetime

Every conversation opened during the current Conan Code run remains live while
the application is open, even when another conversation is selected. Switching
the sidebar selection changes only which conversation is visible.

## Relaunch behavior

Conan Code restores the last visible conversation when the application launches.
Other conversations remain listed and are resumed lazily when selected. A
resumed conversation opens directly through `grok --resume`; Conan Code never
shows a blank shell that requires the user to issue the resume command.

Conan Code does not guarantee that conversations continue working after the
application quits.

## Window and pane layout

Conan Code uses one main macOS window. The selected conversation's root terminal
uses the full content area while no subagent is active. As soon as a subagent
starts, the root terminal keeps the left 50 percent and all active subagent
terminals divide the right 50 percent vertically.

Every root and subagent pane is a fully interactive Grok terminal. Nested
subagents appear at the same visual level as direct subagents, ordered by start
time. A subagent pane opens when the subagent starts and closes when it ends.

## Terminal tabs

Every activated conversation has a compact terminal-tab strip directly beneath
the window title area and above the terminal content. The permanent first tab
is named `main` by default and displays the root Grok pane plus any active
subagent panes. It cannot be closed, remains first when tabs are reordered, and
can be renamed locally without changing the Grok conversation title.

The add button immediately after the last tab creates and selects an independent
Ghostty shell in the conversation's original checkout or worktree directory.
Conan Code supplies no command for these surfaces, so Ghostty uses the user's normal
shell configuration. New shells receive monotonically increasing names such as
`Tab 1` and `Tab 2`; closed numbers are not reused.

Selecting a shell tab gives it the complete terminal content area. The Grok
root and subagents remain mounted and continue running while hidden. Shell tabs
also remain mounted when another tab or conversation is selected. Executing
`exit`, pressing the close button, or using the close-tab shortcut terminates
the shell immediately and selects the tab to its left.

Double-clicking any tab starts inline rename. Enter or losing focus stores the
text exactly as entered; Escape cancels. Empty and duplicate labels are valid.
Shell tabs can be reordered by dragging, but cannot move between conversations.
The strip scrolls horizontally rather than shrinking labels without limit.

Conan Code stores each conversation's tab labels, order, selected tab, and next
number in local metadata. On relaunch it recreates all persisted shell tabs as
new shell processes in the base checkout or worktree; terminal processes and
scrollback do not survive application exit. A missing base directory leaves
the tab visible with an inline error instead of silently using another path.

The tab strip derives its background and foreground from the active Ghostty
configuration. The main tab shows aggregated working, attention, and failure
state. Attention never switches away from a selected shell automatically;
returning to main focuses the pane needing input, or otherwise the last root or
subagent pane used.

Conan Code supports `Command-T` to create a tab, `Command-W` to close a selected
shell, `Command-1` through `Command-8` for exact positions, and `Command-9` for
the last tab. `Command-W` does nothing on main. Equivalent Ghostty tab actions
are routed into Conan Code instead of creating native Ghostty UI.

## Terminal configuration

Every terminal pane loads the user's standard Ghostty configuration, including
fonts, colors, and terminal behavior. Conan Code overrides only the values required
to launch the correct Grok session in the correct working directory through
Conan Code's isolated leader, plus the mouse-capture setting required for native
text selection.

Mouse coordinates, hover, clicks, double clicks, and drag selection remain
fully interactive inside Grok. A normal drag selects terminal text even while
Grok has mouse reporting enabled; normal clicks and double clicks continue to
activate Grok rows and expandable task output. Selected text can be copied with
the standard macOS command or the terminal context menu.

Voice uses Grok's native microphone capture. Conan Code declares the macOS
microphone purpose string, and macOS requests access when the user starts
Voice; Conan Code does not record or persist audio itself.

## Activity and attention

A working conversation shows a spinner in the sidebar. A conversation that
needs user input shows an attention indicator, which takes priority over the
working spinner. Subagent activity and attention propagate to the root
conversation and its project. Opening a conversation that needs attention
focuses the pane requesting input.

Conan Code sends a native macOS notification when a conversation needs attention
only while Conan Code is not the focused application.

## Grok compatibility updates

Conan Code checks the public latest release of the configured Grok fork at launch
and periodically while open. When that release is newer than the installed
binary, an orange warning appears at the right edge of the window toolbar and
opens the matching release page. Network and version-probe failures are
non-blocking and preserve the last successful update state.
