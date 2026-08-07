# Coinor Release

## Release Policy

Coinor is a personal Apple Silicon application for macOS 13 or newer. Release
builds are native Swift 6 SwiftUI/AppKit bundles, run outside App Sandbox, and
are signed locally with an ad-hoc identity.

The bundle is not Developer ID signed, notarized, or intended for the Mac App
Store. A successful `codesign --verify --deep --strict` proves bundle
integrity on the build machine; it does not make the application a notarized
distribution.

Runtime dependencies are deliberately narrow:

- a compatible custom Grok executable at `~/bin/grok`
- Coinor's private Grok leader socket
- statically linked Ghostty v1.3.1 at commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- a Coinor-owned Grok lifecycle hook and bundled relay

Herdr, Paseo, `/Applications/Ghostty.app`, and global `use_leader` are not
runtime dependencies.

## Prerequisites

- Apple Silicon Mac
- macOS 13 or newer
- Xcode and command-line tools with Swift 6
- Developer Tools access enabled for XCTest/XCUITest
- Git
- Python 3
- executable compatible Grok at `~/bin/grok`

Rebuilding Ghostty additionally requires internet access and Xcode's optional
Metal Toolchain. Normal Coinor builds do not require either after
`Vendor/Ghostty` has been installed.

## Prepare Ghostty

`Vendor/Ghostty` is ignored, so a clean clone must create the Xcode-consumed
artifact before building Coinor:

```sh
scripts/ghostty/build.sh
scripts/ghostty/install-app-artifact.sh
scripts/ghostty/verify.sh --artifact-root Vendor/Ghostty
scripts/ghostty/test-verification.sh
```

The verifier binds the Ghostty tag and commit to the public header, static
library, complete XCFramework, resources, and terminfo checksums. Do not mix
files from different Ghostty builds.

## Preflight

Confirm that the standalone repository and Grok integration boundaries still
match the recorded baseline:

```sh
scripts/phase0/check-boundaries.sh
swift test --package-path Tools/CoinorHookRelay
```

The boundary check must not modify `grok-build`, `~/.grok/config.toml`, or the
global Grok leader setting.

## Build

Run the required Debug build and full Debug test before producing Release:

```sh
xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build

xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData test
```

If the test runner reports that automation mode cannot be enabled, verify:

```sh
DevToolsSecurity -status
```

Enabling it changes a macOS developer-security setting and requires explicit
administrator authorization:

```sh
sudo DevToolsSecurity -enable
```

Build the arm64 Release bundle:

```sh
xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build
```

The resulting application is:

```text
.build/DerivedData/Build/Products/Release/Coinor.app
```

## Verify

Run the application-bundle contract:

```sh
APP=.build/DerivedData/Build/Products/Release/Coinor.app
scripts/release/verify-app.sh "$APP"
```

The verifier requires:

- the arm64 Coinor executable
- the arm64 bundled `coinor-hook-relay`
- macOS 13 minimum deployment metadata
- a strict valid ad-hoc signature
- App Sandbox disabled and `get-task-allow` absent
- Ghostty resources and terminfo
- a bundled Ghostty artifact manifest matching `Vendor/Ghostty`
- the Ghostty v1.3.1 MIT notice and exact source commit
- no dynamic dependency on `/Applications/Ghostty.app`

The final release record must also contain the results of:

```sh
scripts/hooks/install.sh "$APP"
scripts/hooks/verify.sh "$APP"
scripts/phase0/check-boundaries.sh
```

Record those results in `docs/verification.md`; do not infer success from an
older application bundle.

## Install

Quit any running copy of Coinor, then install the verified bundle locally:

```sh
APP=.build/DerivedData/Build/Products/Release/Coinor.app
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/Coinor.app"
```

Install or repair the Coinor hook from the installed application:

```sh
scripts/hooks/install.sh "$HOME/Applications/Coinor.app"
scripts/hooks/verify.sh "$HOME/Applications/Coinor.app"
```

Launch it:

```sh
open "$HOME/Applications/Coinor.app"
```

The hook installer refuses to overwrite an unowned registration or relay. If
that happens, inspect `~/.grok/hooks/coinor.json` and
`~/.grok/hooks/coinor-hook-relay`; do not delete or replace unrelated hooks.

## Repair Or Upgrade

For an application-only rebuild:

1. Rebuild and verify Coinor.
2. Replace the local application bundle.
3. Re-run `scripts/hooks/install.sh` using that exact bundle.
4. Re-run both hook and release verification.

For a Ghostty update:

1. Change the pin deliberately.
2. Rebuild the complete header/framework/resources artifact.
3. Install it into `Vendor/Ghostty`.
4. Run the happy-path and corruption verification suite.
5. Rebuild Coinor and repeat all Debug, Release, hook, and manual terminal QA.

Ghostty source components are never upgraded independently.

## Artifact Contents

The Release application contains:

- `Contents/MacOS/Coinor`
- statically linked Ghostty terminal code
- `Contents/Resources/ghostty`
- `Contents/Resources/terminfo`
- `Contents/Resources/coinor-hook-relay`
- `Contents/Resources/GhosttyArtifactManifest.txt`
- `Contents/Resources/ThirdPartyNotices.txt`

Coinor does not bundle Grok itself. It resolves the user's compatible
executable from `~/bin/grok`.

An optional local archive can be created after verification:

```sh
mkdir -p Artifacts
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" Artifacts/Coinor-0.1.0-arm64.zip
shasum -a 256 Artifacts/Coinor-0.1.0-arm64.zip
```

The archive remains an ad-hoc, non-notarized personal build.
