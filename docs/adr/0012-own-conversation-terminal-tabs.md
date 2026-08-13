---
status: accepted
---

# Own conversation terminal tabs in Coinor

Coinor owns a terminal-tab layer inside each conversation runtime. The
permanent main tab displays the existing root and subagent pane layout.
The permanent second tab displays a local IDE layout with `fresh .` and
`lazygit` running in the Git root of the conversation's checkout or worktree.
Additional tabs are independent embedded Ghostty shells launched in the
conversation's persisted working directory without an explicit command.

These tabs are not Grok sessions and do not appear in the project sidebar.
Coinor stores their local identity, label, order, selected state, and monotonic
numbering in its versioned metadata. Grok remains the source of truth for the
conversation title, transcript, and execution state.

The IDE surfaces start eagerly with their conversation runtime and use a fixed
60/40 split. Main and IDE are non-closable fixed tabs; IDE is also
non-renameable. All IDE and shell surfaces remain mounted while their
conversation runtime is live.
Ghostty actions that target tabs are mapped into this Coinor-owned model so
native Ghostty windows or tab chrome never escape the application shell.

ADR 0013 supersedes this ADR's archive-retention and confirmation rules.
Archiving a loaded runtime requires no confirmation and immediately closes main,
IDE, ordinary shell, and managed terminal surfaces.
