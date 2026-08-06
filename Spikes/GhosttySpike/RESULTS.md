# Phase 0 Ghostty Spike Results

Date: August 6, 2026

## Verdict

PASS for the Phase 0 decision: Coinor can embed a real, interactive Ghostty
surface in a native SwiftUI/AppKit macOS application without depending on
`/Applications/Ghostty.app`.

The spike builds and links a pinned static GhosttyKit XCFramework, bundles its
matching resources and terminfo, loads Ghostty user configuration, launches an
absolute command in an absolute working directory, forwards native input and
surface state, suppresses unsupported window/tab/split actions, and tears down
surfaces before the Ghostty application runtime.

## Pinned Build

- Ghostty tag: `v1.3.1`
- Ghostty commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- Ghostty annotated tag object: `22efb0be2bbea73e5339f5426fa3b20edabcaa11`
- Zig: `0.15.2`, downloaded into the ignored local build cache and verified by
  SHA-256
- Optimization: `ReleaseFast`
- XCFramework target: `native`
- Crash reporting: disabled with `-Dsentry=false`
- Deployment target: macOS 13.0
- Swift packages: none

The generated manifest recorded:

```text
ghostty_tag=v1.3.1
ghostty_commit=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
ghostty_version=1.3.1
zig_version=0.15.2
build_mode=ReleaseFast
sentry=false
xcframework_target=native
header_sha256=a619c107e9ab8841f71f91d06bf2bcea7b7c64bf6df252b151812cb932ac9b61
library_sha256=9ce3f69f6177be4fa56773ab96b1c296acb8a4cbc62f6842691cfa0682d7ad49
```

## Host

```text
macOS 26.5.1 (25F80), arm64
Xcode 26.2 (17C52)
Apple Swift 6.2.3
System Zig 0.16.0
```

The system Zig is intentionally not used for Ghostty. The scripts bootstrap
the pinned Zig 0.15.2 toolchain required by Ghostty v1.3.1.

## Reproduction

From the repository root:

```sh
scripts/ghostty/build.sh
scripts/ghostty/verify.sh
Spikes/GhosttySpike/test.sh
Spikes/GhosttySpike/exercise.sh
Spikes/GhosttySpike/minimal-environment.sh
```

`scripts/ghostty/build.sh` requires the official Xcode Metal Toolchain because
Ghostty compiles its Metal shader library through `/usr/bin/xcrun`. When it is
not installed, the script fails before deleting existing artifacts and prints
the installation command:

```sh
xcodebuild -downloadComponent MetalToolchain
```

For the final clean Ghostty build, the official `17C7003j` component was
temporarily imported, the build was run, and the component was removed again:

```sh
xcodebuild -importComponent MetalToolchain \
  -importPath Spikes/GhosttySpike/.build/metal-toolchain-download/MetalToolchain-17C7003j.exportedBundle
scripts/ghostty/build.sh
xcodebuild -deleteComponent MetalToolchain
xcodebuild -showComponent MetalToolchain
```

Final component state:

```text
Build Version: 17C7003j
Status: uninstalled
```

## Direct Evidence

### Static artifact

`scripts/ghostty/build.sh` completed with:

```text
Build Summary: 92/92 steps succeeded
verified_tag=v1.3.1
verified_commit=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
verified_sentry=false
```

The final build log is
`.build/logs/final-ghostty-build.log`. The XCFramework contains a static
`current ar archive`; both the archive and the Swift executable target arm64,
and the archive reports `minos 13.0`.

The matching bundle contains:

- `GhosttyKit.xcframework`
- Ghostty themes and shell integration
- compiled `xterm-ghostty` terminfo
- the manifest and content hashes shown above

### Configuration

`Spikes/GhosttySpike/test.sh` passed:

```text
{"background":"112233","diagnostics":[],"fontSize":23}
config_recursive_load=passed
ghostty_app_dynamic_dependency=absent
```

The fixture root config sets font size 17 and recursively includes a child
config that changes it to 23 and sets the background. The child values being
reported proves recursive config loading. Normal application launches also
load the default user config; the final screenshots visibly use its green text
and dark-purple background, with zero diagnostics recorded.

### Rendering, input, resize, actions, and lifecycle

`Spikes/GhosttySpike/exercise.sh` launches the app bundle through macOS
LaunchServices with `open -n -W`. It passed:

```text
runtime_exercise=passed
surface_create_count=4
surface_destroy_count=4
screenshot_probe=passed
compact_screenshot=732x524
wide_screenshot=1192x844
```

Direct event-log evidence in `.build/runtime-events.log` includes:

- a real Ghostty PTY with `TERM=xterm-ghostty`
- the bundled absolute `TERMINFO` path
- the requested absolute cwd
- visible text containing `Coinor GhosttyKit spike`
- 74 keyboard events sent through `ghostty_surface_key`
- an `ok` marker created by the command typed into the terminal
- scrollback plus handled `scroll_page_up` and `scroll_page_down` actions
- handled selection and `copy_to_clipboard`, with the copied terminal text
  verified through the system pasteboard
- handled `paste_from_clipboard`, with the pasted command creating a second
  marker in the terminal working directory
- exact content resizes to `620x380` and `1080x700`
- no surface recreation during either resize
- `new_window`, `new_tab`, and `new_split:right` callbacks handled and
  suppressed
- exactly one visible window after those actions
- an intercepted URL callback, proving the URL route without launching an
  external application during automation
- a handled close-window action reaching the Coinor-owned close callback
- explicit invisible/visible occlusion updates
- a workspace-wake notification reaching the wake observer
- the backing-property transition path updating scale and display state
- three deliberate surface destructions and recreations
- visible terminal output after recreation
- four surface creates matched by four surface destroys
- runtime destruction and application termination
- no recorded terminal child PID alive after shutdown

The final compact and wide screenshots are `.build/ghostty-spike-compact.png`
and `.build/ghostty-spike-wide.png`. Both were also inspected directly and show
a nonblank, correctly rendered terminal. The image harness independently
reported:

```text
compact: 732x524, 154 quantized colors, luma variance 795.331
wide:    1192x844, 142 quantized colors, luma variance 520.413
```

### Minimal environment and installed-app independence

`Spikes/GhosttySpike/minimal-environment.sh` passed:

```text
minimal_environment_launch=passed
installed_ghostty_read_denied_for_config_and_resources=passed
app_sandbox=disabled
absolute_command=passed
```

The app launched under `env -i` with only the normal Finder-style system path:

```text
/usr/bin:/bin:/usr/sbin:/sbin
```

It started the bundled absolute command, created and destroyed its surface,
destroyed the Ghostty runtime, terminated the application, and left no child
process from that run.

The executable has no dynamic dependency on, or embedded string reference to,
`/Applications/Ghostty.app`. A separate config/resource probe also succeeds
while `sandbox-exec` denies reads below `/Applications/Ghostty.app`. The app
uses the resources and terminfo copied into its own bundle.

## Honest Limitations

- The produced XCFramework is native arm64, not universal. That matches this
  personal macOS/Apple Silicon spike but would need an additional slice for an
  Intel distribution.
- A fresh Ghostty build requires Xcode's optional Metal Toolchain. The build
  script detects this deterministically, but it cannot use a local shim because
  Ghostty's build invokes `/usr/bin/xcrun` directly.
- The final host reported a backing scale of `1.0`. The backing-property
  transition path, scale forwarding, and display-ID forwarding were exercised,
  but moving the window between physical Retina and non-Retina displays was
  not possible on the available single-display setup.
- Invisible/visible occlusion and the workspace-wake notification path were
  exercised. A physical machine sleep/wake cycle was not induced because that
  would suspend the active implementation session.
- A full terminal launch under `sandbox-exec` was attempted as a stronger
  installed-app denial test, but the child process hit macOS's unsupported
  multi-threaded-fork path before shell exec. The final evidence therefore uses
  static dependency/path checks plus a sandbox-denied config/resource probe,
  while the full app is exercised separately in a minimal environment.
- Linking succeeds but emits two warnings about missing debug symbols
  `_ImFontConfig_ImFontConfig` and `_ImGuiStyle_ImGuiStyle` in Ghostty's
  upstream `ext.o`. They did not affect linking or runtime behavior.
- GhosttyKit's C API is not stable. Coinor must retain the exact Ghostty tag and
  commit pin until a deliberate compatibility update is tested.
- During automated runs only, the window rejects external Accessibility-driven
  frame changes so the compact/wide assertions remain deterministic in the
  Codex desktop environment. Normal launches do not apply that restriction.

## Scope

All implementation and generated documentation are confined to:

```text
Spikes/GhosttySpike/**
scripts/ghostty/**
```

Build products, downloaded source, toolchains, logs, screenshots, and fixtures
remain under ignored `.build` or `.cache` directories. No user configuration
was modified, no global state remains changed, and `/Applications/Ghostty.app`
was neither modified nor required by the spike.
