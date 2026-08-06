# Coinor agent rules

Read `CONTEXT.md`, `docs/product-requirements.md`, `docs/architecture.md`,
`docs/implementation-plan.md`, and every accepted ADR before changing code.

## Product boundary

- Coinor is a native Swift 6 macOS 13+ application using SwiftUI and AppKit.
- All Coinor-owned user-visible copy is English.
- Grok owns conversations, titles, transcripts, and execution state.
- Coinor owns presentation, local organization metadata, process coordination,
  and pane layout.
- Do not use Herdr or Paseo as runtime dependencies or copy their source.
- Do not use App Sandbox or target the Mac App Store.
- Do not add third-party Swift packages without explicit user approval.

## Integration boundary

- Treat `/Users/jattentokeyway/projects/github.com/jattento/grok-build` as
  read-only. Never modify its tracked, untracked, generated, or configuration
  files.
- Resolve Grok through an absolute path, defaulting to `~/bin/grok`.
- Use a Coinor-specific `--leader-socket`; never edit `~/.grok/config.toml`.
- Pin Ghostty to tag `v1.3.1`, commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- Build Ghostty's header, static XCFramework, and resources from the same
  revision with crash reporting disabled.
- Coinor's global Grok hook must be inert when Coinor is not running and must
  not overwrite unrelated hooks.

## Delivery

- Phase 0 is a strict gate. Do not build full product UI until all three spikes
  pass and `docs/phase-0-results.md` records real evidence.
- Use `apply_patch` for manual file edits.
- Keep changes within the ownership assigned by the root agent.
- Do not weaken, skip, disable, or delete tests.
- Do not push or create a remote repository.
- Commit only when the root agent asks.
