# Telegram remote work

Status: accepted after grilling. ADR-0015 records the architectural
decision. This note is the product contract for implementation.

Telegram is capable enough. The feature needs no webhook, no Coinor
network listener, and no second conversation identity.

## Locked decisions

1. **Same Conversation.** A phone thread is the sidebar Conversation,
   same Grok Session, title, pin, and archive. Telegram is a surface,
   like a pane.
2. **One Remote Topic = one Conversation.** Not “each General message
   starts work”, not “the whole chat is one Conversation at a time”.
3. **Paired Chat is a private bot chat with topics**, not a group.
   Communities and informal “subgroups” are topics by another name, or
   a different Telegram product. Do not use them.
4. **One bot token and pairing per Conan Code installation.** Paste the
   token in Settings (Keychain). A one-time `/start <code>` allowlists
   that Telegram user and binds that chat. Everyone else is ignored.
   A remote host in the sidebar is not a pairing.
5. **Local Projects only for v1.** `/new`, `/find`, and share only see
   repos on the Mac that is polling. SSH remotes stay desktop-only;
   that computer should have its own Conan Code + bot if you want it
   on Telegram.
6. **How a Remote Topic appears.**
   - `/new`, or creating a topic in the paired chat, starts a
     Conversation, then a short Project list and Main Checkout vs New
     Worktree (same two actions as the sidebar `+`).
   - Share from the Mac attaches an existing Conversation.
   - `/find` is the existing agentic search: describe it, pick a
     result, that Conversation gets a topic.
7. **The phone can always send and it interrupts.** An in-flight turn
   is preempted. Do not type into Ghostty; use ACP `session/prompt`.
8. **Permission prompts are buttons on that Remote Topic.** Allow once
   / Deny (and Grok’s allow-always if it offers it). Either surface may
   answer; the first wins. Remote work does not imply always-approve.
9. **Conan Code must be running.** Long-poll `getUpdates`. No daemon
   after quit. Telegram drops unclaimed updates after 24 hours.
10. **Subagents stay in the parent topic.** They never become chat
    messages. At most a started subagent updates the one working draft
    (`Working… explore`). Progress and finish events are silent. They
    are not Conversations and do not get topics.
11. **Archive closes the topic** and further messages are ignored until
    unarchive. Deleting the topic only drops the surface; it does not
    archive or delete the Grok Session.
12. **Grok title wins.** Coinor updates the topic name. Telegram
    renames are not a display-title alias.
13. **Media is the next turn.** Photo, file, or voice note join the
    prompt. Voice is transcribed on the Mac (same idea as Voice) and
    may also be attached.
14. **What the phone sees.** One working draft, then the streamed
    assistant answer as that same draft, then one final message.
    Permission prompts stay buttons. Never one Telegram message per
    tool or subagent event.
16. **What the Mac sees.** A phone turn of the selected Conversation
    appears live in the conversation view as a Coinor overlay (user
    text, then the streamed answer). Coinor does not type into the
    Ghostty PTY. The durable transcript stays in Grok.
15. **Inspiration only.** Read OpenClaw, Hermes, CCGram for patterns
    (pairing codes, topic isolation, one-message streaming, approval
    buttons, draft fallback). Implement a Coinor-owned `URLSession`
    client. No Node sidecar, no PTY typer, no Swift package unless
    later approved.

## Mapping

| Telegram | Coinor / Grok |
| --- | --- |
| One bot + one private chat | One Conan Code installation |
| Forum topic | One Conversation / Grok Session |
| Message in that topic | One user turn (`session/prompt`) |
| Draft / rich reply | Streamed assistant answer |
| Inline buttons | Permission prompt / ask-user-question |
| Topic title | Grok session title |
| General / pairing topic | Status, `/new`, `/find` — not a Conversation |
| Subagent | Working draft of the parent topic, never a chat message |
| Phone turn on the Mac | Live overlay on the conversation view |

## Why this transport

`getUpdates` long-polls `api.telegram.org` from the Mac. Outbound HTTPS
is not a Coinor network listener. Webhooks need a public HTTPS URL on
443/80/88/8443 and are rejected.

Telegram private-chat topics exist since Bot API 9.3 (31 Dec 2025);
bots can create them since 9.4. Streaming drafts and rich messages
exist in 9.5–10.2. Unclaimed updates last at most 24 hours.

## Implementation sketch

No third-party Swift package unless explicitly approved.

- `Coinor/Telegram/` — Bot API client and long poller
- pairing + allowlist in Keychain; mapping in `MetadataStore`
- `TelegramBridge` started by `AppCoordinator` after the Grok leader
- ACP `session/new`, `session/load`, `session/prompt` on
  `GrokControlClient`

Phased:

1. Pairing, allowlist, poller, echo in the pairing topic
2. `/new` + picker → ACP session + first prompt
3. Topic mapping, resume, title sync, user-created topic = `/new`
4. Share from the Mac and `/find`
5. Draft / rich streaming and tool-status line
6. Permission buttons and interrupt
7. Photos, files, voice transcription

Tests mock Telegram HTTP and assert mapping, allowlist, and ACP calls.

## Inspiration (not dependencies)

- **RichardAtCT/claude-code-telegram** (2.8k stars, SDK not PTY):
  `/verbose 0` quiet mode is the phone UX we want — typing stays
  active, only the final answer is a message. Do not copy the
  Python sidecar, webhook server, or classic 13-command terminal.
- **terranc/claude-telegram-bot-bridge**: streaming drafts, tool-call
  messages off by default. Same lesson: do not dump tools into chat.
- **OpenClaw** (MIT): pairing code, `chat_id`+`thread_id` isolation,
  button approvals, edit-one-message streaming. Default group ingest
  is something we do not want; we are not using a group.
- **Hermes**: native `sendMessageDraft` with edit fallback; local STT
  for voice. Tool approval is weaker than we want.
- **CCGram / CoderBOT / hanxiao / philmcneely:** topic ≈ session, but
  they type into tmux/PTY. Do not copy that. Coinor already has a
  control plane.

## Sources

- https://core.telegram.org/bots/api
- https://core.telegram.org/bots/api-changelog
- https://core.telegram.org/bots/features#privacy-mode
- Grok agent mode: `session/new`, `session/prompt`, `session/update`
- Coinor: `CONTEXT.md`, ADR-0008, ADR-0014, ADR-0015
