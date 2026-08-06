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
Coinor's isolated leader.

## Activity and attention

A working conversation shows a spinner in the sidebar. A conversation that
needs user input shows an attention indicator, which takes priority over the
working spinner. Subagent activity and attention propagate to the root
conversation and its project. Opening a conversation that needs attention
focuses the pane requesting input.

Coinor sends a native macOS notification when a conversation needs attention
only while Coinor is not the focused application.
