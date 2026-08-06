# Coinor

Coinor is a personal macOS application that organizes durable Grok
conversations by project while preserving the native Grok terminal experience.

## Language

**Project**:
A logical Git repository discovered from Grok conversations or registered
manually in Coinor. It includes conversations from the main checkout and from
any worktree belonging to the same repository. Independent clones remain
separate projects even when they share a remote URL.
_Avoid_: Folder, workspace, worktree group

**Conversation**:
A top-level user-visible unit backed by one root Grok session. Conversations
appear directly under their project regardless of their working directory.
_Avoid_: Task, pane, Herdr session

**Pinned Conversation**:
A conversation promoted to Coinor's top-level Pinned section for quick access.
Pinning changes only Coinor's organization metadata.
_Avoid_: Pinned session, favorite Grok session

**Grok Session**:
The durable technical conversation state owned and persisted by Grok. Coinor
references it without duplicating its transcript or execution lifecycle.
_Avoid_: Coinor task, conversation record

**Worktree**:
An alternate checkout belonging to a project that determines where a
conversation executes. It is conversation context, not a navigation level.
_Avoid_: Subproject, conversation group

**Pane**:
A live, interactive terminal view of a Grok session. A pane can appear or
disappear without changing the identity of the conversation it displays.
_Avoid_: Conversation, session

**Conversation View**:
The content area for the selected conversation. Its root pane uses the full
area when no subagent is active; otherwise the root keeps the left half and all
active subagent panes share the right half.
_Avoid_: Window, project

**Subagent Pane**:
A live, interactive pane backed by a child Grok session. It appears alongside
its parent conversation while the subagent is available without becoming a
conversation in the project list. Nested subagents appear at the same visual
level as direct subagents, ordered by when they started.
_Avoid_: Child conversation, task
