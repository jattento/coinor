---
status: superseded
superseded-by: 0011-use-groks-native-acp-subagent-lifecycle
---

# Install an inert global Grok hook

Coinor registers its lifecycle relay under `~/.grok/hooks/` because interactive
leader-connected Grok clients cannot load a process-local `--plugin-dir`. The
relay returns immediately, sends events asynchronously to Coinor, and is inert
when Coinor is not running or the event does not belong to a Coinor runtime.

This decision was retired after the native ACP stream was verified to publish
and replay the required subagent lifecycle. Keeping the relay would duplicate
Grok behavior and expose hook execution noise in every session.
