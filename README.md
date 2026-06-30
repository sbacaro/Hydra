<div align="center">

<img src="docs/assets/hydra-icon.png" width="124" alt="Hydra app icon" />

# Hydra

**An audio patch bay for your Mac.**

Route any source to any destination — apps, hardware, plug‑ins and the network — in one visual matrix.

[![Version](https://img.shields.io/badge/version-1.0.8-2997ff)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-26%20Tahoe-1d1d1f)](#system-requirements)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](#build--run)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%26%20Intel-555)](#system-requirements)

[**Download**](https://github.com/sbacaro/Hydra-Soundcard/releases/latest) ·
[Website](https://sbacaro.github.io/Hydra-Soundcard/) ·
[Changelog](CHANGELOG.md) ·
[Issues](https://github.com/sbacaro/Hydra-Soundcard/issues)

</div>

---

Hydra is a virtual audio patch bay for macOS: eight selectable **Hydra Audio Bridge**
devices (2 to 128 channels each) that any app can pick as its input or output,
routed freely between apps, hardware, plug‑ins and the network — all in a single
visual matrix. Per‑app capture, capture flows, VST3 in the signal path, AES67
(incl. Dante) and NDI over the wire, scenes, recording and OSC remote control.

**Free and open source (GPL‑3.0).** The audio bridges and the hidden engine hub are
a customized [BlackHole](https://github.com/ExistentialAudio/BlackHole) driver (see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).

Current version: **1.0.8** · Requires **macOS 26 (Tahoe)** · Architecture overview in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Features

- **Eight Hydra Audio Bridges** (2‑A, 2‑B, 4, 8, 16, 32, 64, 128 channels) — fixed loopback devices any app can select as input or output, toggled on/off in the sidebar.
- **The grid** — a Dante Controller–style matrix. Click a cross‑point to connect a transmitter to a receiver; a pin lights when audio is flowing. Available as a full grid or a per‑destination **List**.
- **Flux — capture flows** — a dedicated view, alongside Grid and List, that taps a device's **output** (whatever any app is playing to it) and routes it into Hydra **continuously, without changing your system output**. Each flow is a signal chain you edit in place — capture, then send wherever you want — with the same inserts and level controls as the rest of the grid.
- **Per‑app capture** — grab the audio of individual apps via Core Audio process taps (macOS 14.4+ API), while the app keeps playing normally.
- **Physical devices in the grid**, with drift‑corrected resampling (ASRC) across independent clocks.
- **Stereo ganging** — link an odd+even pair into one stereo lane; it patches and unpatches together (L→L / R→R).
- **VST3 channel strips** — inserts + trim with live plug‑in editor windows, crash‑isolated by default. Plug‑ins load **only when something is patched through them**.
- **Network audio** — AES67/Dante RX (SAP/SDP + RTP) and experimental AES67 TX; NDI RX/TX via the user‑installed runtime (never bundled — GPL‑safe). Per‑bridge AES67 / NDI transmit.
- **Scenes** (matrix snapshots), channel labels, WAV recording, and **OSC** remote control.
- **Menu bar extra** with glanceable status, scene recall and quick actions.
- **Localized in six languages** — English, Português (Brasil), Español, Français, Deutsch and Italiano, with an in‑app language switcher.

## Download & Installation

### Quick install (recommended)

Download the installer from the latest [GitHub release](https://github.com/sbacaro/Hydra-Soundcard/releases/latest):

```bash
curl -L https://github.com/sbacaro/Hydra-Soundcard/releases/download/v1.0.8/Hydra-1.0.8.pkg -o Hydra.pkg
open Hydra.pkg
```

### Manual installation

Download the [ZIP archive](https://github.com/sbacaro/Hydra-Soundcard/releases/download/v1.0.8/Hydra-1.0.8.zip) and run:

```bash
unzip Hydra-1.0.8.zip
cd Hydra-1.0.8
sudo bash install.sh
```

The installer puts the app in `/Applications` and installs the audio driver to
`/Library/Audio/Plug‑Ins/HAL` (one admin prompt). On first run, complete the
Welcome flow and grant the requested permissions (audio capture, microphone).

### Updates

After the first install, Hydra updates itself. It checks GitHub for new releases
on launch and every 24 h and, when one is found, downloads the installer, verifies
it against its published SHA‑256 checksum, and installs it after a single macOS
password prompt — then relaunches. The app and audio driver are updated together.
You can also check anytime via **Hydra ▸ Check for Updates…**. Maintainers: see
[`Packaging/RELEASING.md`](Packaging/RELEASING.md).

## System requirements

- **macOS 26.0 (Tahoe)** or later
- Apple Silicon (arm64) or Intel (x86_64)
- Administrator privileges for driver installation
- **SIP can remain enabled** (the driver loads as an AudioServerPlugIn)

## Architecture

Hydra runs as a **single process**. The app, the audio engine and the local
control server all live in `Hydra.app`:

- **`Hydra.app`** — the SwiftUI UI **and** the audio engine. The engine
  (`HydraDaemon`, a framework: audio I/O, device/app/network managers) starts
  in‑process at launch via `DaemonRuntime.start()` and serves a local WebSocket
  on `127.0.0.1:59731`. The UI is a client of that loopback socket — the server
  just happens to run in the same process, so you see one app in Activity Monitor.
- **HAL drivers** — eight `HydraAudioBridge*.driver` loopback devices plus a
  hidden `HydraVirtualSoundcard.driver` engine hub, installed to
  `/Library/Audio/Plug‑Ins/HAL` by the installer. They load inside `coreaudiod`,
  not as a Hydra process; the engine attaches a bridge's audio path only while
  it's patched.
- **`hydra-plugin-host`** — a small helper spawned **only while a VST3 plug‑in is
  loaded**, so a plug‑in crash can't take down audio. It exits when no plug‑ins
  are hosted.

On first run, Hydra requests the necessary permissions and starts the engine
automatically.

## Build & run

The Xcode project is generated by a script (not committed). One‑time setup:

```bash
# 1. Tooling: the project generator needs the xcodeproj gem.
sudo gem install xcodeproj           # or: brew install ruby && gem install xcodeproj

# 2. Fetch the Steinberg VST3 SDK (also fetched automatically at build time).
./Scripts/fetch_vst3sdk.sh
```

Then, whenever the project structure changes (or on a fresh checkout):

```bash
ruby Scripts/generate_xcodeproj.rb   # writes Hydra.xcodeproj
```

Open `Hydra.xcodeproj` in Xcode, then **Product → Clean Build Folder** and
**Run** (⌘R). Building the `HydraApp` scheme also builds and embeds the driver,
the `HydraDaemon` engine framework and the `hydra-plugin-host` helper. On first
launch, complete the Welcome flow to install the soundcard driver.

### Code signing (recommended for development)

macOS privacy permissions (TCC, e.g. system audio capture) are tied to the app's
code signature. With ad‑hoc signing (`-`) the signature changes every build, so
granted permissions reset after a rebuild. Create a stable self‑signed
certificate once and the generator will use it automatically:

> Keychain Access → Certificate Assistant → Create a Certificate → name
> **"Hydra Dev"**, Identity Type: *Self‑Signed Root*, Certificate Type:
> *Code Signing*.

Regenerate the project afterwards. Without the cert, builds fall back to ad‑hoc
signing (works, but permissions may need re‑approval after rebuilds).

## Project layout

| Path | What |
|---|---|
| `Sources/HydraCore` | Shared constants, data model, WebSocket messages (single source of truth) |
| `Sources/hydrad` | `HydraDaemon` framework — audio engine, managers, local WebSocket server, process taps. Runs in‑process inside the app (`DaemonRuntime.start()`) |
| `Sources/HydraApp` | SwiftUI app + the in‑process engine; UI is a client of the loopback WebSocket (Localizable String Catalog) |
| `Sources/HydraVST` | VST3 hosting shim (C++ over the Steinberg VST3 SDK) |
| `Sources/HydraNDIShim` | C facade that `dlopen()`s the proprietary NDI runtime at run time |
| `Sources/HydraModuleABI` | ABI for external plug‑in modules (`.dylib`, never bundled) |
| `Backplane/` | The eight Hydra Audio Bridge loopback devices + hidden engine hub (customized BlackHole) |
| `Media.xcassets` | App icon (the Hydra waveform; the UI follows the macOS system accent) |
| `Scripts/` | `generate_xcodeproj.rb`, `generate_icons.py`, `fetch_vst3sdk.sh`, `host_build.sh`, `install_local.sh` |
| `docs/` | The project website (GitHub Pages) |
| `Tests/` | Unit tests (parsers, matrix, message round‑trips) |

## Using it

1. **Add what you want to route.** Turn on a Hydra Audio Bridge (sidebar →
   **Manage Bridges…**), enable a physical device under **Devices**, or capture an
   app under **Apps**. Only the bridges/devices/apps you add appear in the grid;
   point any app at a bridge in its own audio settings.
2. **Patch in the grid.** Click a cell (transmitter column → receiver row), or use
   a cell's **channel strip** in the Inspector (Connect / Remove, gain, meters).
   Prefer a per‑destination view? Switch to **List**.
3. **Capture and route with Flux.** Switch to the **Flux** view, add a flow, pick
   the device to capture and where to send it. Select a flow to open its
   Transmitter, Receiver and Connection in the inspector — inserts and level work
   exactly as in the grid.
4. **Stereo.** Turn **Stereo** on at both ends in the channel strip (or right‑click
   a channel header → *Link … as Stereo Pair*). The pair collapses into one stereo
   lane and routes L→L / R→R.
5. **Plug‑ins.** Select a channel or cell and add **VST3 inserts** with live editor
   windows. They run crash‑isolated by default.
6. **Network.** Under **Network**, subscribe to AES67/Dante streams or NDI sources;
   flag a bridge as AES67/NDI **TX** to broadcast it.
7. **Scenes / recording / OSC.** Save and recall matrix snapshots, record any
   interface's output to WAV, and drive Hydra from consoles/TouchOSC/Stream Deck
   over OSC.

Settings, matrix, scenes, labels and channel strips persist under
`~/Library/Application Support/Hydra/` (JSON), so your setup survives app restarts.

> **Note:** on a loopback bridge, routing a channel back to itself (In N → Out N)
> creates a feedback loop. Feedback protection (Settings → Safety) blocks these by
> default.

## Support & feedback

- **Issues:** https://github.com/sbacaro/Hydra-Soundcard/issues
- **Discussions:** https://github.com/sbacaro/Hydra-Soundcard/discussions
- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- **Build & testing:** [`docs/BUILD.md`](docs/BUILD.md) · [`docs/TESTING.md`](docs/TESTING.md)
- **Changelog:** [`CHANGELOG.md`](CHANGELOG.md)

## License

GPL‑3.0 — see [`LICENSE`](LICENSE). Third‑party components and their licenses are
listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The Steinberg VST3
SDK is fetched by `Scripts/fetch_vst3sdk.sh` (GPLv3 option) and the NDI runtime is
loaded at run time from the user's own install — neither is committed to this
repository.

Dante® is a registered trademark of Audinate Pty Ltd. NDI® is a registered
trademark of Vizrt NDI AB. VST® is a registered trademark of Steinberg Media
Technologies GmbH. Hydra is an independent project and is not affiliated with,
sponsored by, or endorsed by Apple Inc., Audinate, Vizrt or Steinberg.

---

<div align="center">

**Latest release:** [Hydra 1.0.8](https://github.com/sbacaro/Hydra-Soundcard/releases/tag/v1.0.8) · Released June 29, 2026

© 2026 Hydra Audio · Free software under the GNU General Public License v3.0

</div>
