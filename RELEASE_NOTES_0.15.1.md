# Hydra Audio 0.15.1 beta

**Release Date:** June 14, 2026

## Overview

Hydra Audio is a professional-grade audio patch bay for macOS with:
- **256×256 virtual soundcard** backplane (built on BlackHole)
- **Per-app audio capture** (Core Audio process taps, macOS 14.4+)
- **AES67/Dante interoperability** (SAP/SDP/RTP)
- **VST3 plugin hosting** (channel strips with live editors)
- **NDI audio streaming** (receive/transmit)
- **Scenes & disk recording** (WAV)
- **OSC remote control** (TouchOSC, Stream Deck, consoles)

Licensed under **GPL-3.0**. Built on BlackHole (GPL-3.0) and the Steinberg VST3 SDK (GPLv3 option).

## What's in This Release

### Binaries (universal arm64 + x86_64)
- **HydraApp.app** — SwiftUI application (user interface)
- **hydrad** — Background daemon (audio engine, 4.6 MB)
- **HydraVirtualSoundcard.driver** — 256×256 virtual audio backplane
- **install.sh** — Automated installation script
- **uninstall.sh** — Uninstallation script

### System Requirements
- **macOS 26.0 (Tahoe)** or later
- Apple Silicon (arm64) or Intel (x86_64)
- Administrator access for installation
- **SIP can remain enabled** (driver loads as AudioServerPlugIn)

## Installation

### Quick Install
```bash
unzip Hydra-0.15.1-beta.zip
cd Hydra-0.15.1-beta
sudo bash install.sh
```

The installer will:
1. Install binaries to `/usr/local/hydra`
2. Install the audio driver to `/Library/Audio/Plug-Ins/HAL`
3. Create a LaunchDaemon for automatic startup
4. Restart Core Audio

### Manual Installation
See `README.txt` in the archive for detailed steps.

## Usage

### Launch the App
After installation:
```bash
open -a Hydra
```

Or find it in Applications → Hydra.

### Start the Daemon (if not auto-running)
```bash
/usr/local/hydra/hydrad
```

The daemon will:
- Initialize the audio engine
- Listen for WebSocket connections from HydraApp
- Manage all audio routing and AES67 discovery

### First Steps
1. Open Hydra app
2. The grid shows your available audio sources and destinations
3. Click cells to create patches (connections)
4. Use the Inspector (right panel) to adjust gain and monitor levels
5. Save your setup as a **Scene** for quick recall

## Features by Phase

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Core grid engine | ✓ Complete |
| 2 | Physical device routing + ASRC | ✓ Complete |
| 2b | Drift correction | ✓ Complete |
| 3 | Per-app audio capture | ✓ Complete |
| 4 | AES67 RX (Dante interop) | ✓ Complete |
| 5 | PTP sync + AES67 TX | 🔧 In progress |
| 6 | VST3 channel strips | ✓ Complete |
| 7 | Scenes, robustness, polish | ✓ Mostly done |

## Recent Changes (v0.15.1)

### Performance
- **Grid no longer observes 10 Hz meters** — Signal LEDs are now tiny leaf views (SignalDot), re-rendering only four-pixel dots instead of rebuilding the entire grid
- **Cell lookups are a Set, not a filter** — O(1) per cell instead of O(cells × connections) on every hover move
- **Daemon skips identical meter broadcasts** — Idle system sends nothing; real audio changes every tick

### UX Improvements
- Device bars on both axes (Dante Controller style)
- Visible lattice with hairline edges
- Channel labels rotated to vertical
- Type scale raised to match macOS system ramp
- Grid panel clips with rounded shape

For full changelog, see `CHANGELOG.md` in the repository.

## Documentation

Complete documentation is available in the GitHub repository:

- **PROJETO_HYDRA_FUNDACAO.md** — Complete architecture, design, and roadmap
- **CHANGELOG.md** — Full version history
- **THIRD_PARTY_NOTICES.md** — Licenses and credits
- **README.md** — Quick start and testing phases

Repository: https://github.com/sbacaro/Hydra

## Testing Phases

### Phase 2: Basic Grid Routing
1. Set an app's output to "Hydra Virtual Soundcard"
2. Play audio
3. In Hydra, patch In 1 → Out 3, In 2 → Out 4
4. Verify audio appears at outputs 3–4

### Phase 2b: Physical Devices + Drift Correction
1. Enable a physical device in Devices tab
2. Patch Hydra inputs to the device
3. Play for several minutes — no clicks or drift

### Phase 3: Per-App Capture
1. Open Apps tab
2. Find a playing app (green speaker icon)
3. Toggle capture (allows audio-capture permission on first use)
4. App appears as two source rows (L/R)
5. Patch to speaker or monitor

### Phase 4: AES67 Reception (requires Dante hardware)
1. Enable bridged networking on VM
2. Dante device in AES67 mode appears in Network tab
3. Multicast flow appears under Streams
4. Toggle subscribe → audio flows through grid

### Phase 6: VST3 Channel Strips
1. Install a VST3 plugin to `/Library/Audio/Plug-Ins/VST3`
2. Restart daemon
3. Select a source channel
4. Click Insert → search plugin → select
5. Plugin editor opens; tweak parameters live
6. Audio processes in real-time

## Uninstallation

```bash
sudo bash uninstall.sh
```

This will:
- Stop the daemon
- Remove the driver
- Delete binaries from `/usr/local/hydra`
- Restart Core Audio

## Known Limitations

- **PTP sync not yet implemented** — AES67 TX is experimental (Phase 5 remainder)
- **NDI runtime must be installed separately** — Download from https://ndi.link/NDIRedistV6Apple
- **No browser-based remote control yet** — OSC remote works; web UI is Phase 3 of Hydra Remote

## Support & Feedback

- **Issues:** https://github.com/sbacaro/Hydra/issues
- **Discussions:** https://github.com/sbacaro/Hydra/discussions
- **License:** GPL-3.0 (see LICENSE file)

## Credits

- **BlackHole** (GPL-3.0) — Virtual audio driver foundation
- **Steinberg VST3 SDK** (GPLv3 option) — Plugin hosting
- **NDI Runtime** (proprietary, loaded at runtime) — Network audio
- **Apple Core Audio** — macOS audio architecture

## License

Hydra Audio is free software licensed under **GPL-3.0**.

See `LICENSE` file in the repository for full text.

---

**Build Info:**
- Version: 0.15.1 beta
- Build Date: June 14, 2026
- Architectures: arm64 + x86_64 (universal)
- Platform: macOS 26.0 (Tahoe)
- Xcode: 26.5
