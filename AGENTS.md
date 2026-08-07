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

- Treat the sibling custom `grok-build` checkout as read-only. Never modify
  its tracked, untracked, generated, or configuration files from Coinor work.
- Resolve Grok through an absolute path, defaulting to `~/bin/grok`.
- Use a Coinor-specific `--leader-socket`; never edit `~/.grok/config.toml`.
- Pin Ghostty to tag `v1.3.1`, commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- Build Ghostty's header, static XCFramework, and resources from the same
  revision with crash reporting disabled.
- Receive subagent lifecycle through Grok's native ACP stream. Do not install
  or modify global Grok hooks.

## Delivery

- Phase 0 is a strict gate. Do not build full product UI until all three spikes
  pass and `docs/phase-0-results.md` records real evidence.
- Use `apply_patch` for manual file edits.
- Keep changes within the ownership assigned by the root agent.
- Do not weaken, skip, disable, or delete tests.

## Public repository and release discipline

- This repository must remain public. If no remote exists, create the public
  `jattento/coinor` GitHub repository before the first release; never publish
  Coinor from a private repository.
- Never commit or release credentials, tokens, cookies, private keys, private
  configuration, credentialed URLs, user data, or machine-specific private
  paths. Before every push and release, scan the complete commit delta,
  tracked and untracked files, application bundle, archives, and release notes
  with Gitleaks plus targeted credential-pattern and local-path checks.
- A completed change is not done when it only works locally. Once the requested
  change is validated and accepted, commit it and push `main` without waiting
  for a separate user request.
- Increment the app version, create an annotated version tag, and publish a new
  public GitHub Release only when the distributable Coinor application changes.
  Documentation and policy-only changes are pushed without building or
  releasing a new application unless the user explicitly asks for one.
- Every release must point at the pushed `main` commit and include the verified
  arm64 `Coinor.app` archive, `SHA256SUMS`, concise release notes, the exact
  commit, and validation results. GitHub's uploaded asset digests must match
  the local checksums.
- Install the exact verified release bundle locally after publication so the
  running application and public rollback artifact are identical.
- Do not publish partial or failing work. Preserve the previous release and tag
  as the rollback point; never replace an existing release asset or move a
  published version tag.
