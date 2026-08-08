---
status: accepted
---

# Own conversation terminal tabs in Coinor

Coinor owns a terminal-tab layer inside each conversation runtime. The
permanent main tab displays the existing root and subagent pane layout.
Additional tabs are independent embedded Ghostty shells launched in the
conversation's original checkout or worktree without an explicit command.

These tabs are not Grok sessions and do not appear in the project sidebar.
Coinor stores their local identity, label, order, selected state, and monotonic
numbering in its versioned metadata. Grok remains the source of truth for the
conversation title, transcript, and execution state.

All shell surfaces remain mounted while their conversation runtime is live.
Ghostty actions that target tabs are mapped into this Coinor-owned model so
native Ghostty windows or tab chrome never escape the application shell.
