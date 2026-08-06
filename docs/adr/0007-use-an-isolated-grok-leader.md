---
status: accepted
---

# Use an isolated Grok leader

Coinor launches its root and subagent Grok clients through a dedicated leader
socket so multiple terminal panes can follow the same live session. It passes
the leader configuration only to Coinor-owned processes and does not require a
machine-wide `use_leader` setting.
