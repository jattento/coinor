---
status: accepted
---

# Mirror ego lite Browser Spaces as a Conan Code tab

Conan Code passively recognizes when a Grok session running inside it drives
the third-party `ego-browser` CLI (the automation runtime the `ego lite`
browser ships, https://lite.ego.app) and opens a read-only preview tab of the
exact Task Space it is using. The tab updates on a bounded poll cadence and
closes itself as the agent's Task Space activity opens, continues, and
finishes.

Detection reads the same generic ACP `tool_call` notification stream Coinor
already consumes for the terminal-control nonce (ADR-0013): a
`run_terminal_command` invocation whose command drives `ego-browser` is
parsed for `useOrCreateTaskSpace`/`takeOverTaskSpace` (opened) and
`completeTaskSpace`/`closeTaskSpace` (closed) calls, entirely from the
already-observed command text. This requires no new ACP method, no new
control socket, and no cooperation from the agent beyond calling the already
public `ego-browser` skill the way its own documentation already mandates —
unlike managed terminal tabs (ADR-0013), there is no agent-facing protocol to
create or drive a Browser Mirror tab.

Once open, a per-tab poller shells out to the user's installed `ego-browser`
CLI and captures one screenshot per tick through the Chrome DevTools
Protocol, adapting cadence to whether the tab is visible. The CLI is treated
exactly like an optional external dependency: if it is missing, the tab
reports so instead of blocking anything else.

A new Coinor-owned skill, `conan-code-browser`, installed the same way as
Conan Code's other bundled skills, steers agents toward `ego-browser` over
any other browser tool while running inside Conan Code and explains that the
preview is automatic. It does not modify the third-party `ego-browser` skill
files, which `ego lite` refreshes on its own — Conan Code owns only its own
skill's lifecycle, the same boundary every other bundled skill already keeps.

This is a local-only feature: `ego lite` is a per-machine app, so the
detection subscription is never wired for remote-host control connections,
the same carve-out ADR-0013 already established for managed terminal tabs.

Rejected alternative: driving a live video stream via
`Page.startScreencast` instead of polled `Page.captureScreenshot` calls.
Continuous CDP screencast frames tie to the tab's actual on-screen
compositing and are unreliable for a Task Space that is not the foreground
Space in `ego lite`'s own window, while a forced `captureScreenshot` per poll
works regardless of foreground state and was validated end to end (cold
~700ms, warm ~100-160ms) before this feature was built.
