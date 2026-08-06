---
status: accepted
---

# Install an inert global Grok hook

Coinor registers its lifecycle relay under `~/.grok/hooks/` because interactive
leader-connected Grok clients cannot load a process-local `--plugin-dir`. The
relay returns immediately, sends events asynchronously to Coinor, and is inert
when Coinor is not running or the event does not belong to a Coinor runtime.
