---
status: superseded by ADR-0005
---

# Use Herdr as the headless terminal runtime

Coinor would have used Herdr through its public API and terminal-session bridge
to own PTYs, running processes, restoration, and subagent panes. Coinor would
not have embedded the Herdr TUI: it would have rendered projects,
conversations, and pane layout itself, while Grok remained the source of truth
for conversation state.
