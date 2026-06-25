# Building Hydra

The Xcode project is **generated** — `Hydra.xcodeproj` is a build artifact, not
committed. The declarative source of truth is **`project.yml`** (XcodeGen).

## Quick start

```bash
brew install xcodegen          # once
xcodegen generate              # writes Hydra.xcodeproj from project.yml
open Hydra.xcodeproj
```

Or build the pure modules + tests without Xcode:

```bash
swift test                     # HydraCore + HydraRT (incl. the ring/resampler tests)
```

## Targets

| Target | Kind | Notes |
|--------|------|-------|
| HydraCore | framework | Constants, models, WS protocol, pure DSP math (resampler, servo) |
| HydraRT | framework | Real-time SPSC ring + polyphase resampler (split out so it's testable) |
| HydraVST / HydraNDIShim / HydraModuleABI / HydraPluginHostABI | frameworks (C/C++) | ABIs + VST3 shim |
| HydraDaemon | framework | Audio engine — runs in-process inside the app (formerly the `hydrad` daemon) |
| hydra-plugin-host | app | Out-of-process VST host (crash isolation) |
| HydraApp | app | SwiftUI UI + the in-process engine; embeds the driver, HydraDaemon, frameworks, and the plugin host |
| HydraVirtualSoundcard | .driver | AudioServerPlugIn backplane (macOS 11 target) |
| HydraCoreTests / HydraRTTests | unit tests | Logic + real-time ring/resampler (run under ASan/TSan in CI) |

## Migration note (XcodeGen)

The build moved from a hand-rolled Ruby generator to XcodeGen. Validate on a Mac:

```bash
xcodegen generate
xcodebuild build -scheme HydraApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme HydraCore   -destination 'platform=macOS'
xcodebuild test  -scheme HydraRTTests -destination 'platform=macOS'
```

Known things to check/adjust after migration:

- **Code signing:** `project.yml` uses ad-hoc (`-`). For stable macOS privacy
  permissions (TCC, e.g. audio capture) across rebuilds, set `CODE_SIGN_IDENTITY`
  to your self-signed `Hydra Dev` cert (Keychain Access → Certificate Assistant)
  — e.g. via a local `.xcconfig` or by editing `project.yml`.
- **Helpers:** the app embeds `hydra-plugin-host` into `Contents/Library/Helpers`
  (spawned on demand for VST crash isolation). The audio engine is the embedded
  `HydraDaemon.framework` — there is no separate daemon process or LaunchAgent.
- **VST3 SDK:** fetched by a pre-build script on HydraVST (`Scripts/fetch_vst3sdk.sh`).

## Fallback generator

`Scripts/generate_xcodeproj.rb` (xcodeproj gem) is kept as a fallback and is
known-good. If XcodeGen ever falls short:

```bash
gem install xcodeproj
ruby Scripts/generate_xcodeproj.rb
```
