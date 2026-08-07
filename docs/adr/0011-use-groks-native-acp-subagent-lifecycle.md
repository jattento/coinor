---
status: accepted
---

# Use Grok's native ACP subagent lifecycle

Coinor consumes `subagent_spawned`, `subagent_progress`, and
`subagent_finished` updates from its existing Grok ACP control connection.
Persisted lifecycle updates are recursively replayed when a conversation opens
or the private leader reconnects.

Coinor does not install global Grok hooks, bundle an auxiliary relay, or own a
lifecycle Unix socket. Pane cleanup still combines native finish updates with
persisted terminal outcomes and root-process exit so cancellation and abrupt
termination cannot leave stale descendants.

This keeps Grok as the source of truth, removes per-prompt hook execution noise,
and reduces Coinor's runtime and release surface without changing the panel
layout or interactivity contract.
