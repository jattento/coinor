---
status: accepted
---

# Present conversations on Telegram

Conan Code may present the same Conversation on a paired Telegram private chat,
one forum topic per Conversation, so the operator can work from a phone without
a public IP. Telegram is a surface, not a second identity: Grok still owns the
session, title, transcript, and execution. Coinor long-polls Telegram outbound,
drives turns through ACP `session/prompt`, and stores only pairing, allowlist,
and topic mapping.

This rejects a forum group per installation (extra members and privacy-mode
footguns), Communities/"subgroups" as a different Telegram product, webhooks
(inbound listener), PTY keystroke injection, a keep-alive after quit, and
exposing SSH remote projects on Telegram in v1. Each installation has its own
bot token. A phone message may interrupt an in-flight turn. Tool permission
prompts are answered with buttons on that topic, not by switching the session
to always-approve.

## Considered options

- **Forum group per install.** The original sketch. Worse pairing and
  membership; only needed if several humans share one Mac.
- **Webhook / tunnel.** Needs a public HTTPS URL. Coinor does not listen.
- **Type into the Ghostty PTY.** What CCGram/CoderBOT-style bridges do.
  Fragile, and Coinor already refuses to infer state from terminal output.
- **Same sidebar catalog including SSH remotes.** Cheap to route (each remote
  already has an ACP client) but the phone then needs two-machine failure UX.
  Each computer should have its own bot instead.
- **Queue phone messages while Grok is working.** Safer; rejected in favor of
  interrupt so the phone can actually steer.

## Consequences

- Conan Code must be running. Telegram holds unclaimed updates at most 24
  hours; quitting the app still stops work.
- `GrokControlClient` must grow `session/new`, `session/load`, and
  `session/prompt`. The TUI is no longer the only driver.
- Mapping (session id ↔ topic) is Coinor organization metadata, same class as
  pin and archive.
- Open-source Claude↔Telegram bots are inspiration only (pairing codes,
  topic isolation, draft streaming, approval buttons, quiet verbosity).
  RichardAtCT/claude-code-telegram is the reference for “final answer,
  not a transcript of tools.” No vendored sidecar, no third-party Swift
  package without a later explicit approval.
- Phone presentation is one working draft, permission buttons, and one
  final answer. Subagent lifecycle stays on the Mac panes.
- A phone turn is also presented live on the Mac conversation view as a
  Coinor overlay. The Ghostty TUI is not the renderer for ACP-driven
  turns.
