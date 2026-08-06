---
status: accepted
---

# Own terminal and pane lifecycle in Coinor

Coinor launches Grok inside its embedded terminal surfaces and owns the visual
pane layout. It does not use Herdr as a runtime because continuing work while
Coinor is closed is not a requirement; Grok hooks provide subagent lifecycle
events, and Coinor opens or closes child-session panes in response.
