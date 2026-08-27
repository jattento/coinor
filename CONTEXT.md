# Conan Code

Conan Code is a personal macOS application that organizes durable Grok
conversations by project while preserving the native Grok terminal experience.
The repository, module, app bundle, and compatibility identifiers retain the
internal name `Coinor`.

## Language

**Project**:
A logical Git repository discovered from Grok conversations or registered
manually in Conan Code. It includes conversations from the main checkout and from
any worktree belonging to the same repository. Independent clones remain
separate projects even when they share a remote URL.
_Avoid_: Folder, workspace, worktree group

**Conversation**:
A top-level user-visible unit backed by one root Grok session. Conversations
appear directly under their project regardless of their working directory.
_Avoid_: Task, pane, Herdr session

**Pinned Conversation**:
A conversation promoted to Conan Code's top-level Pinned section for quick access.
Pinning changes only Conan Code's organization metadata.
_Avoid_: Pinned session, favorite Grok session

**Grok Session**:
The durable technical conversation state owned and persisted by Grok. Conan Code
references it without duplicating its transcript or execution lifecycle.
_Avoid_: Conan Code task, conversation record

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

**Terminal Tab**:
A Conan Code-owned tab within one conversation view. The permanent first three
tabs contain the Grok conversation layout, the local IDE layout, and the local
Git layout; additional tabs contain independent Ghostty shells rooted at the
conversation's original checkout or worktree.
_Avoid_: Conversation, Grok session, native Ghostty tab

**Main Tab**:
The permanent, non-closable terminal tab that contains the root Grok pane and
any active subagent panes. Its local label defaults to `main` and can be
renamed without changing the Grok conversation title.
_Avoid_: Root conversation, sidebar title

**IDE Tab**:
The permanent, non-closable second terminal tab. It runs `fresh .` alone, full
width, at the Git root of the conversation's checkout or worktree.
_Avoid_: Shell tab, editor session, project view, Git tab

**Git Tab**:
The permanent, non-closable third terminal tab. It runs `lazygit` alone, full
width, at the same Git root as the IDE tab.
_Avoid_: Shell tab, IDE tab, project view

**Shell Tab**:
A closable terminal tab backed by an independent Ghostty shell. Its process and
scrollback live only while Conan Code is running; its local name, order, and
selection metadata survive relaunch.
_Avoid_: Grok session, subagent pane

**Browser Mirror Tab**:
A closable terminal tab showing a read-only, periodically refreshed preview of
an `ego-browser` Task Space that a root or subagent session is driving. Conan
Code opens, updates, and closes it automatically by passively observing the
same terminal-command activity every `ego-browser` invocation already
produces; it is never created or controlled through an agent-facing protocol
of its own, and it never appears for remote-host conversations.
_Avoid_: Shell tab, managed terminal tab, browser tab

**Code Tour**:
A one-step highlighted range of code and an explanatory comment that Grok
opens in the existing IDE tab through the `conan-code-tour` Fresh plugin.
Conan Code queues the request from Grok's native tool call; it renders no
view of its own.
_Avoid_: Point to code, walkthrough, guided tour

**Subagent Pane**:
A live, interactive pane backed by a child Grok session. It appears alongside
its parent conversation while the subagent is available without becoming a
conversation in the project list. Nested subagents appear at the same visual
level as direct subagents, ordered by when they started.
_Avoid_: Child conversation, task
