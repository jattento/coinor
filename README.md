# Conan Code

Conan Code is a personal, native macOS workspace for organizing durable Grok
conversations by local Git project. It embeds interactive Ghostty terminals,
restores exact Grok sessions, and shows active subagents beside the root
conversation in a fixed 50/50 layout. Each conversation also has persistent
terminal tabs: a permanent Grok `main` view, a permanent two-pane `IDE` view
with Fresh and Lazygit, plus independent Ghostty shells in the same checkout
or worktree.

Grok remains the source of truth for session IDs, titles, transcripts, and
execution. Conan Code stores only local organization metadata such as pins,
archives, manually registered projects, sidebar ordering, the last visible
conversation, and local terminal-tab labels and layout.

The repository, Xcode target, app bundle, bundle identifiers, and local data
paths retain the internal name Coinor for compatibility.

## Requirements

- Apple Silicon Mac running macOS 13 or newer
- Xcode with Swift 6 and the macOS command-line tools
- Git and Python 3
- A compatible custom Grok executable at `~/bin/grok`
- Fresh available as `fresh`
- Lazygit available as `lazygit`
- Internet access and Xcode's optional Metal Toolchain only when rebuilding
  the pinned Ghostty artifact

Conan Code runs outside App Sandbox and uses a local ad-hoc signature. It is not
notarized and is not intended for App Store distribution.

Conan Code does not require Herdr, Paseo, `/Applications/Ghostty.app`, or a global
Grok `use_leader` setting.

## First Build

`Vendor/Ghostty` is intentionally ignored by Git. A clean clone must first
build and install the pinned Ghostty v1.3.1 artifact:

```sh
scripts/ghostty/build.sh
scripts/ghostty/install-app-artifact.sh
scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty
```

The Ghostty build is pinned to commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. Its public header, static
XCFramework, resources, and terminfo are treated as one indivisible artifact.

Build Conan Code:

```sh
xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build
```

Run the exact Debug application:

```sh
open .build/DerivedData/Build/Products/Debug/Coinor.app
```

## Test And Release

```sh
scripts/ghostty/test-verification.sh

xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData test

xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build

APP=.build/DerivedData/Build/Products/Release/Coinor.app
scripts/release/verify-app.sh "$APP"
```

See [Release](docs/release.md) for the complete local release and installation
procedure. Final test evidence and the acceptance mapping are recorded in
[Verification](docs/verification.md) and
[Acceptance Matrix](docs/acceptance-matrix.md).

## Local Installation

After the Release bundle passes verification:

```sh
APP=.build/DerivedData/Build/Products/Release/Coinor.app
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/Coinor.app"
open "$HOME/Applications/Coinor.app"
```

## Local Data

- `~/Library/Application Support/Coinor/metadata.json`: Conan Code organization
  and UI metadata
- `~/Library/Application Support/Coinor/grok-leader.sock`: private Grok leader
  socket while Conan Code is running

Grok's own storage remains authoritative for conversation content. Removing
Conan Code metadata does not delete Grok sessions.

## Limits And Licensing

Conan Code is Apple Silicon only, local-only, non-sandboxed, ad-hoc signed, and
not notarized. Conversations are not guaranteed to continue after Conan Code
quits. The application intentionally targets the compatible custom Grok build
at `~/bin/grok`, not arbitrary Grok releases.

Conan Code copies no Herdr or Paseo source. Embedded terminal support uses the
pinned Ghostty v1.3.1 source under its MIT license; the application bundle
includes the corresponding third-party notice and artifact manifest.

The product contract is defined by:

- [Product Requirements](docs/product-requirements.md)
- [Architecture](docs/architecture.md)
- [Implementation Plan](docs/implementation-plan.md)
- [Phase 0 Results](docs/phase-0-results.md)
