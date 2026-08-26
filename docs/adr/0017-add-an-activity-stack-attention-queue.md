---
status: accepted
---

# Add an Activity Stack attention queue

Conan Code offers a toolbar-opened Activity Stack: a single queue of
conversations waiting on the user (needs input, failed, or finished), ordered
by how much each one blocks the user, so answering agents does not require
manually switching sidebar rows one at a time. It is opened only by an
explicit toolbar click or `⌘⇧A`; it never raises itself, and it never opens a
window of its own — it replaces the sidebar's own conversation list with the
queue while presented, the same way the sidebar's Agent Search panel already
takes over that column, and the content area shows the focused conversation
directly.

The queue's candidate pool is every known, non-dormant, non-archived
conversation, not only conversations already loaded into a runtime this run.
This is a deliberate difference from Conan Code's existing sidebar attention
tracking (`AppCoordinator.pendingAttention`), which is edge-triggered per
loaded `ConversationRuntime` and therefore blind to a conversation the user
never opened this session. `ActivityStackModel` keeps its own independent
`ConversationAttention.transition` bookkeeping over `AppCoordinator.summaries`
and `roster` instead of reusing or widening `pendingAttention`, so this
feature cannot destabilize the already-tested sidebar/notification behavior:
it is purely additive and reads `AppCoordinator`'s existing public surface.

The pure ordering and suppression rules — reason derivation (needs input
outranks failed outranks finished), longest-waiting-first within a group,
dismiss, mute, snooze, and push-to-end — live in `ActivityStackEngine`, a
stateless function of candidates plus carried-forward tracking dictionaries.
`ActivityStackModel` is the only stateful layer, holding that tracking state
and `AppCoordinator` access.

The focused item is never a second terminal surface: Conan Code never parses
terminal output to infer state, and this feature keeps that boundary by
rendering `RuntimeHostView`, the exact component the normal conversation
content area uses (tab strip and always-mounted runtimes included), and
activating/resuming through the existing `AppCoordinator.selectConversation`
path. Answering it is exactly the terminal input already in use for text,
image, and audio; returning to `working` removes the item from the queue on
its own — but only advances the panel to another conversation if one is
actually waiting. A conversation that stops blocking with nothing else
queued stays on screen (with only a "Close" action) instead of snapping to
an empty state and back on every turn of a multi-question exchange.

Queue membership, pushed order, mutes, and snoozes are session-only: none of
it is persisted, and none of it survives a relaunch. A muted or snoozed
conversation still resurfaces once it raises a new instance of attention (a
fresh failure, a new question, or a new finish) — mute and snooze remove an
instance of attention, not the conversation's ability to ask again.
`.completed` ("session closed") is excluded from the queue outright rather
than read as a one-shot "finished" edge, matching how it is already excluded
from project-level attention elsewhere in Conan Code; treating it as an edge
kept an already re-answered conversation stuck in the queue.

Rejected alternative: a physical single-card stack with the rest of the queue
only peeking from behind it, and a separate in-panel rail column duplicating
the sidebar (both from an early design exploration). Rejected in favor of
letting the Activity Stack replace the sidebar's own list — reusing existing
visual language, avoiding a second parallel list, and needing no
card-stacking animation. A "Pause Queue" control was also removed after
shipping: once advancing is conditioned on another conversation actually
waiting, a manual pause added no behavior a sticky focus did not already
provide.
