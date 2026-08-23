# Coinor Release

## Release Policy

Coinor is a personal Apple Silicon application for macOS 13 or newer. Release
builds are native Swift 6 SwiftUI/AppKit bundles, run outside App Sandbox, and
are signed locally with an ad-hoc identity.

The source repository and every GitHub Release are public. Every completed,
validated change is committed and pushed. A change that modifies the
distributable application also increments the build version and produces a new
immutable release so another computer can install the same artifact and an
earlier tag can be used for rollback. Documentation and policy-only changes do
not require a new application release.

The bundle is not Developer ID signed, notarized, or intended for the Mac App
Store. A successful `codesign --verify --deep --strict` proves bundle
integrity on the build machine; it does not make the application a notarized
distribution.

Runtime dependencies are deliberately narrow:

- a compatible custom Grok executable at `~/bin/grok`
- Fresh available as `fresh`
- Lazygit available as `lazygit`
- Coinor's private Grok leader socket
- statically linked Ghostty v1.3.1 at commit
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`

Herdr, Paseo, `/Applications/Ghostty.app`, and global `use_leader` are not
runtime dependencies. Coinor receives subagent lifecycle through Grok's native
ACP stream and does not install files in `~/.grok/hooks`.

## Prerequisites

Run the unattended-development gate before any build, test, UI automation, or
release work:

```sh
scripts/dev/preflight.sh
```

The gate pins the validated Xcode build and macOS SDK combination and checks the
Xcode license, first-launch components, Developer Tools access,
`system.privilege.taskport`, automation mode without authentication, Swift 6,
the arm64 macOS destination, and writable build/temp directories. The host
macOS version is reported, not enforced. It never changes system configuration. If it fails,
perform the printed administrator or GUI remediation while a human is present,
then rerun it successfully before starting unattended work.

- Apple Silicon Mac
- macOS 13 or newer
- Xcode and command-line tools with Swift 6
- Developer Tools access enabled for XCTest/XCUITest
- Git
- Python 3
- executable compatible Grok at `~/bin/grok`
- executable Fresh available as `fresh`
- executable Lazygit available as `lazygit`

Rebuilding Ghostty additionally requires internet access, Xcode's optional Metal
Toolchain, a patched Zig 0.15.2 (`brew install zig@0.15`) and
`llvm-libtool-darwin` (`brew install llvm@20`). Stock Zig 0.15.2 from
ziglang.org cannot link against the Xcode 26 SDK, and Apple's `libtool` from
Xcode 26 silently drops archive members that are not 8-byte aligned, which
removes the Ghostty core from the static library. `COINOR_ZIG_BIN` and
`COINOR_LIBTOOL_BIN` override both tools. Normal Coinor builds require none of
this after `Vendor/Ghostty` has been installed.

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
library, complete XCFramework, resources, and terminfo checksums, and asserts
that the static library still exports the Ghostty entry points the app calls.
Checksums alone cannot catch an archiver that drops members: the archive stays
well formed and matches its own manifest while exporting nothing. Do not mix
files from different Ghostty builds.

## Prepare the Grok changelog

The Settings changelog tab reads a cooked snapshot of the Grok fork releases
from the application bundle. Refresh it before a release so the shipped app
documents the Grok version it was built against:

```sh
scripts/grok-changelog/cook.py
```

The script downloads the `jattento/grok-build` releases and their per-release
commit ranges from the GitHub API, splits each release into fork changes and
upstream (xAI) changes, strips validation and security boilerplate, and writes
`Coinor/Resources/GrokChangelog.json`. The result is committed with the source;
the application never calls the GitHub API for it.

## Build

Run the required Debug build and full Debug test before producing Release:

```sh
xcodebuild -project Coinor.xcodeproj -scheme Coinor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build

scripts/dev/run-tests.sh
```

Run the suite through `scripts/dev/run-tests.sh` rather than calling
`xcodebuild test` directly. A running Conan Code already owns the
`dev.coinor.Coinor` bundle identifier, so XCUITest cannot launch the built
application and the unit-test host fails the same way, reporting
`Could not launch "Coinor". The LaunchServices launcher has returned an error`.
The script terminates every running instance first and runs the suite under
`caffeinate`, so display sleep cannot lock the session and abort the
user-interface tests.

If the test runner reports that automation mode cannot be enabled, verify:

```sh
DevToolsSecurity -status
```

Enabling it changes a macOS developer-security setting and requires explicit
administrator authorization:

```sh
sudo DevToolsSecurity -enable
```

If the test runner instead raises a system authentication dialog for
`system.privilege.taskport`, an unattended run cannot answer it. Granting the
right once removes the dialog permanently:

```sh
sudo security authorizationdb write system.privilege.taskport allow
```

XCUITest asks `testmanagerd` to enter automation mode, a privileged machine
state guarded by Authorization Services instead of by an authorization database
right. Until the machine is configured to enter it without authenticating, every
run raises a Touch ID or password dialog that caches nothing, and an unattended
runner dies with `Timed out while enabling automation mode`. Neither
`DevToolsSecurity -enable` nor the `taskport` grant covers it, and `sudo` does
not satisfy it either: the tool authenticates an administrator in the shell.
Configure it once:

```sh
automationmodetool enable-automationmode-without-authentication
```

`automationmodetool` with no arguments reports the state; it must print
`DOES NOT REQUIRE user authentication`. The setting survives reboots.

`scripts/dev/preflight.sh` checks the `taskport` grant and the automation mode
state, and refuses to continue while either is missing, so an unattended run
fails with the remediation printed instead of stopping on a dialog nobody is
there to answer.

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
- macOS 13 minimum deployment metadata
- a strict valid ad-hoc signature
- App Sandbox disabled and `get-task-allow` absent
- Ghostty resources and terminfo
- a bundled Ghostty artifact manifest matching `Vendor/Ghostty`
- the Ghostty v1.3.1 MIT notice and exact source commit
- no dynamic dependency on `/Applications/Ghostty.app`

Record those results in `docs/verification.md`; do not infer success from an
older application bundle.

Coinor no longer pins the Grok runtime to a recorded revision. The integration
boundaries that matter are enforced in the product itself: an absolute Grok
path, Coinor's private leader socket, and no writes into `grok-build` or
`~/.grok/config.toml`. A release must still leave those untouched.

## Install

Quit every running copy of Conan Code. `/Applications/Coinor.app` is the only
canonical installation. Unregister and remove stale duplicates before
replacing it with the exact verified bundle:

```sh
APP=.build/DerivedData/Build/Products/Release/Coinor.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$LSREGISTER" -u "$HOME/Applications/Coinor.app" 2>/dev/null || true
rm -rf "$HOME/Applications/Coinor.app"
rm -rf /Applications/Coinor.app
ditto "$APP" /Applications/Coinor.app
```

Launch the canonical bundle and verify the running executable path, version,
build, and SHA-256 against the published asset:

```sh
open /Applications/Coinor.app
```

Do not consider the release installed while a duplicate `Coinor.app` remains
under `~/Applications` or another user-facing application location. Build
products may remain in DerivedData, but LaunchServices, Spotlight, Dock, and the
running process must resolve the user-facing app to `/Applications/Coinor.app`.

## Repair Or Upgrade

For an application-only rebuild:

1. Rebuild and verify Coinor.
2. Replace the local application bundle.
3. Re-run release verification.

For a Ghostty update:

1. Change the pin deliberately.
2. Rebuild the complete header/framework/resources artifact.
3. Install it into `Vendor/Ghostty`.
4. Run the happy-path and corruption verification suite.
5. Rebuild Coinor and repeat all Debug, Release, and manual terminal QA.

Ghostty source components are never upgraded independently.

## Artifact Contents

The Release application contains:

- `Contents/MacOS/Coinor`
- statically linked Ghostty terminal code
- `Contents/Resources/ghostty`
- `Contents/Resources/terminfo`
- `Contents/Resources/GhosttyArtifactManifest.txt`
- `Contents/Resources/ThirdPartyNotices.txt`
- `Contents/Resources/GrokChangelog.json`
- `Contents/Resources/coinorctl`
- `Contents/Resources/conan-code-long-running-SKILL.md`
- `Contents/Resources/conan-code-terminal.sh`
- `Contents/Resources/sidechat-SKILL.md`
- `Contents/Resources/sidechat.sh`
- `Contents/Resources/managed-terminal-bootstrap.zsh`

Coinor does not bundle Grok itself. It resolves the user's compatible
executable from `~/bin/grok`. At startup, Conan Code installs its bundled skills
into `~/.grok/skills/conan-code-long-running` and `~/.grok/skills/sidechat` with
private permissions. The managed-terminal bootstrap remains inside the application
bundle and is sourced only by Conan Code-owned terminal tabs.

An optional local archive can be created after verification:

```sh
VERSION="$(plutil -extract CFBundleShortVersionString raw \
  "$APP/Contents/Info.plist")"
mkdir -p Artifacts
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "Artifacts/Coinor-${VERSION}-arm64.zip"
shasum -a 256 "Artifacts/Coinor-${VERSION}-arm64.zip"
```

The archive remains an ad-hoc, non-notarized personal build.

## Security Gate

Run the security gate before the first push and again against the exact release
candidate:

```sh
git diff --check
scripts/release/security-scan.sh "$APP"
```

The script scans Git history, a clean snapshot containing exactly tracked and
non-ignored untracked files, and every regular file in the application bundle
for secrets and the local home path. Also inspect the complete release diff and
archive contents for credentials, tokens, private keys, credentialed URLs,
Coinor metadata, Grok transcripts, or other user data. A non-empty finding
blocks the push and release until it is understood and removed.

Build outputs, DerivedData, the ignored Ghostty artifact, Application Support
metadata, and the private leader socket must never be committed.

## Publish

The first release creates the public repository if it does not already exist:

```sh
gh repo create jattento/coinor --public --source=. --remote=origin
```

For every release:

1. Update `MARKETING_VERSION` when the user-facing version changes and always
   increment `CURRENT_PROJECT_VERSION`.
2. Complete Debug build, full test, Release build, bundle verification,
   visual QA, and the security gate.
3. Create the verified archive and checksum file:

```sh
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
mkdir -p Artifacts
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "Artifacts/Coinor-${VERSION}-arm64.zip"
(
  cd Artifacts
  shasum -a 256 "Coinor-${VERSION}-arm64.zip" > SHA256SUMS
)
```

4. Commit the validated source, push `main`, and create an annotated tag:

```sh
git push origin main
git tag -a "v${VERSION}" -m "Conan Code ${VERSION}"
git push origin "v${VERSION}"
```

5. Publish the public GitHub Release:

```sh
gh release create "v${VERSION}" \
  "Artifacts/Coinor-${VERSION}-arm64.zip#Conan Code macOS arm64 application" \
  "Artifacts/SHA256SUMS#SHA-256 checksums" \
  --repo jattento/coinor \
  --title "Conan Code ${VERSION}" \
  --notes-file "docs/releases/${VERSION}.md" \
  --verify-tag
```

6. Verify that GitHub's asset digests match the local checksums, that `main`
   and the annotated tag resolve to the release commit, and that the release is
   public rather than draft or prerelease.
7. Quit Conan Code, replace the installed application with the exact verified
   release bundle, reopen it, and confirm the installed version and primary
   workflow.

Never move a published tag or replace an existing release asset. A correction
gets a new version and release; the previous one remains the rollback point.
