# Testing — coverage & roadmap

How Hydra is tested, what is covered today, and what is deliberately out of
reach of unit tests (and why).

## Strategy

Hydra is three modules with very different testability:

- **HydraCore** — pure value types, protocol, and parsers. Imports only
  Foundation, so it compiles and runs in a normal SwiftPM test bundle. **This
  is where the test suite lives**, and where we push as much logic as possible.
- **HydraApp** — SwiftUI. Views can't be meaningfully unit-tested, so the
  *logic* behind them is extracted into HydraCore and tested there.
- **hydrad** — the audio daemon. It's an executable target that touches Core
  Audio, sockets and real hardware. The *pure* slices (routing validation,
  feedback detection, resampler servo, PTP parsing) are extracted into
  HydraCore and tested; the real-time/audio/network parts are not unit-tested
  (see "Out of scope").

The guiding move: **extract pure logic into HydraCore, then test it there.**
This keeps one test target, avoids fragile `@testable import` of an executable,
and means the daemon/app call the *same* code the tests exercise (not a copy).

Run with `swift test`, or ⌘U in Xcode.

## What is covered (HydraCoreTests)

Pre-existing suites: `PatchMatrixTests`, `MessagesTests`, `NodeIDTests`,
`OscTests`, `Aes67Tests`, `PluginManagementTests`.

Added in this pass:

| File | Covers |
|------|--------|
| `OscParserExtraTests` | OSC bundles (nesting, depth cap, multi-element, zero/oversized elements), `T`/`F` tags, unknown-type termination, truncation, `firstInt`/`firstString` |
| `Aes67ParserExtraTests` | SAP rejection (version, IPv6, encrypted, compressed, too-short, auth-word skipping, MIME filtering); SDP edge cases (missing c=/m=, channel cap, default channels, dash name, TTL strip, origin from `o=`, payload-type matching, case-folding) |
| `ModelsTests` | `Connection.id` format & directionality, `PatchPoint` hashing, `Node.displayName` fallback, `NodeDirections` OptionSet + Codable, `NodeKind.allCases`, Codable round-trips (Node, PatchScene, HydraEvent) |
| `GainTests` | dB↔linear reference values, silence floor, magnitude of negatives, round-trip across range, monotonicity |
| `UILogicTests` | `EnginePresence` state machine + labels, `LoadSeverity` thresholds, `formatElapsed`, `ChannelPairing` console rules (mono/stereo) |
| `PatchValidationTests` | per-node-kind endpoint bounds, backplane feedback/cycle detection (self-loop, direct, transitive, fan-out, device-hop) |
| `ResampleServoTests` | nominal step from rates, fill-level servo (clamping, proportionality), underrun detection |
| `PtpParsingTests` | PTP timestamp decode, EUI-64 identity, Announce dataset, BMCA precedence, robust median |

## Production refactors made for testability

These moved logic out of untestable contexts into HydraCore. They change
production code, so **build once in Xcode to confirm** (the suite was authored
without a local Swift toolchain):

- `Sources/HydraCore/UILogic.swift` — `EnginePresence`, `LoadSeverity`,
  `formatElapsed`, `ChannelPairing`. `MenuBarPanel` and `DaemonClient` now
  delegate to these.
- `Sources/HydraCore/PatchValidation.swift` — `endpointPlausible`,
  `wouldFeedback`. `MatrixStore` delegates to these.
- `Sources/HydraCore/ResampleServo.swift` — servo math. `ChannelRing` delegates
  (the per-sample interpolation stays inline for RT performance).
- `Sources/HydraCore/PtpParsing.swift` — timestamp/identity/dataset/median.
  `PtpClock` delegates.

## Out of scope for unit tests (and why)

- **AudioEngine IOProc / mixing** (`hydrad/AudioEngine.swift`, MatrixStore RT
  path) — runs on the Core Audio callback against real hardware clocks; uses
  vDSP over unsafe buffers. Needs an integration harness with a virtual device,
  not a unit test.
- **`ABLUtil` flatten/distribute** — pure-ish, but operates on
  `AudioBufferList`; testing means constructing CoreAudio buffer lists by hand.
  Candidate for a future targeted test if buffer-interleaving bugs appear.
- **Network I/O** — `OscServer`, `Aes67Manager`, `Aes67Tx`, `PtpClock` sockets,
  `MulticastReceiver`. The *parsing* is tested; the socket plumbing is not.
- **Resource/lifecycle managers** — `DeviceManager`, `ProcessTapManager`,
  `RecordingManager`, `NdiManager`, `ModuleManager`, `DaemonService`,
  `InstallManager`. These drive Core Audio, the filesystem, processes and the
  NDI runtime.
- **SwiftUI views** — rendering and interaction. The logic behind them is
  tested via the extractions above.

## Next steps (toward higher coverage)

1. **App/daemon UI flows** — add a `HydraUITests` XCUITest target (launch,
   patch a cell, save/recall a scene, start/stop a recording). Requires a built
   app and a macOS CI runner; assertions are on-screen, not in-process.
2. **Audio integration** — a headless harness that installs the virtual
   backplane, pushes known signals through the matrix, and asserts on captured
   output (verifies mixing, gain, resampling end-to-end).
3. **`ABLUtil`** — unit-test flatten/distribute by building small
   `AudioBufferList`s in the test.
4. **CI** — a GitHub Actions macOS workflow running `swift test` on every push
   (the daemon/app build there too, catching the refactors above).

Note: 100% line coverage including the real-time audio path and UI is not a
realistic or honest target — the audio engine and views are validated by
running the app, not by unit tests. The aim here is to cover *all logic that
can be made pure*, which is what the extractions accomplish.
