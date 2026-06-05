# Hydra Audio

Audio patch bay + per-app capture + AES67 controller for macOS, around a single
patching grid, with VST3 in the signal path. **GPL-3.0.** Built on
[BlackHole](https://github.com/ExistentialAudio/BlackHole) (see `THIRD_PARTY_NOTICES.md`).

Full design: [`PROJETO_HYDRA_FUNDACAO.md`](PROJETO_HYDRA_FUNDACAO.md).
Current version: **0.15.1 beta** (see [`CHANGELOG.md`](CHANGELOG.md)). Requires macOS 26 (Tahoe).

## Features

- 256×256 virtual soundcard (backplane) with a Dante Controller-style patch grid
- Virtual interfaces: named slices of the pool, sized independently per direction
- Physical devices in the grid with drift-corrected resampling (ASRC)
- Per-app capture (Core Audio process taps, macOS 14.4+ API)
- AES67/Dante RX (SAP/SDP + RTP) and experimental AES67 TX (pre-PTP)
- NDI RX/TX via the user-installed runtime (never bundled — GPL-safe)
- VST3 channel strips (inserts + trim) with live plugin editors
- Scenes, channel labels, disk recording (WAV), OSC remote control

## Layout

| Path | What |
|---|---|
| `Sources/HydraCore` | Shared constants, data model, WS messages (single source of truth) |
| `Sources/hydrad` | Daemon — audio engine, managers, local WebSocket server (`127.0.0.1:59731`) |
| `Sources/HydraApp` | SwiftUI app — client of the daemon (UI only) |
| `Sources/HydraVST` | VST3 hosting shim (C++ over the Steinberg VST3 SDK) |
| `Sources/HydraNDIShim` | C facade that `dlopen()`s the proprietary NDI runtime |
| `Backplane/` | Backplane (256×256 virtual soundcard) build script — used by `host_build.sh` |
| `Scripts/` | Workflow commands: `host_build.sh` (host), `vm_install.sh` (VM), `fetch_vst3sdk.sh` |
| `Tests/` | Unit tests (parsers, matrix, message round-trips) |
| `dist/` | Build output staged for the VM (created by `host_build.sh`, not committed) |

## Workflow: build on the host, test on the VM

The host Mac is build-only. Testing happens on a macOS VM (UTM) that mounts
this project folder over SMB. One command on each side:

### On the HOST (build everything)

Requirements: macOS 14+ SDK, Xcode.

```bash
./Scripts/host_build.sh            # tests + driver + binaries → dist/
./Scripts/host_build.sh --skip-tests
```

Runs `swift test`, builds the backplane driver (clones BlackHole pinned tag,
applies the Hydra overrides: 256ch, name, bundle ID), builds `hydrad` and
`HydraApp` universal (arm64 + x86_64), signs everything ad-hoc and stages it
all in `dist/`. Nothing is installed on the host.

### On the VM (install everything)

The shared folder mounts on the VM at `/Volumes/Hydra Virtual Soundcard/`.
Use `bash` — execute bits may not survive SMB:

```bash
bash "/Volumes/Hydra Virtual Soundcard/Scripts/vm_install.sh"             # install
bash "/Volumes/Hydra Virtual Soundcard/Scripts/vm_install.sh" status      # check
bash "/Volumes/Hydra Virtual Soundcard/Scripts/vm_install.sh" uninstall   # remove
```

Installs the driver to `/Library/Audio/Plug-Ins/HAL`, copies the binaries to
`/usr/local/hydra` (local disk — running off SMB is unreliable), clears
quarantine, restarts `coreaudiod` and verifies the device. SIP stays on.

### Running (on the VM)

```bash
/usr/local/hydra/hydrad     # terminal 1
/usr/local/hydra/HydraApp   # terminal 2
```

### Phase 2 test — route audio through the grid

1. On the VM, set an app's (or the system's) **sound output to "Hydra Virtual
   Soundcard"** and play music. The app writes to channels 1–2, which loop back
   as grid sources In 1–2.
2. In Hydra, click cells **In 1 → Out 3** and **In 2 → Out 4**. The engine now
   mixes those sources to outputs 3–4 (which loop back as inputs 3–4).
3. Select a cell: the **Inspector** shows the live meter; drag the **gain**
   slider and watch the level follow. Right-click a cell (or use the Inspector
   button) to remove a connection.
4. To *hear* the result, record from the Hydra device in any app that lets you
   pick input channels 3–4 (e.g. QuickTime captures 1–2 only — toggle
   In 1 → Out 1... careful: on a loopback device, routing In N → Out N
   creates a feedback loop. Prefer distinct channels).

**Phase 2 is done when:** toggling cells audibly changes what arrives at the
destination channels, with the gain slider controlling the level.

### Phase 2b test — physical devices + drift correction

1. In Hydra, open **Devices** (grid header) and enable the VM's audio output
   device (e.g. "Apple Virtual Machine Audio" / built-in output). Its channels
   appear in the grid tinted with the accent color.
2. Play music into "Hydra Virtual Soundcard" (system output) and patch
   **In 1 → \<device\> 1** and **In 2 → \<device\> 2**.
3. **You should hear the audio** on the VM's speakers — that's the engine
   crossing clock domains through the ring + servo resampler (ASRC).
4. Leave it playing for several minutes: no clicks or drift build-up.
5. Toggle the device off/on (or unplug/replug a USB interface): the patch
   re-binds automatically (Section 7.8).

**Phase 2b is done when:** audio routed between devices with independent
clocks stays clean after several minutes.

### Phase 3 test — per-app capture

1. Keep the VM's **system output on the speakers** (NOT on Hydra — that's the
   point of this phase).
2. Play audio in some app (Safari/Music).
3. In Hydra, open **Apps**, find the app (green speaker = playing) and toggle
   capture. macOS asks for audio-capture permission on first use — allow it.
   If no prompt appears, enable `hydrad` manually in System Settings →
   Privacy & Security → Screen & System Audio Recording, then retry.
4. The app appears as two source rows (L/R). Patch **app L/R → speaker
   device 1/2** (device enabled in Devices) — you hear it duplicated, or patch
   to any backplane channel and watch the Inspector meter move.

**Phase 3 is done when:** a chosen app's audio flows through the grid while
the app keeps playing to its normal output.

### Phase 4 test — AES67 reception (PENDING — requires Dante hardware)

Prerequisites (why this can't be tested without gear):
- UTM VM network in **bridged mode** (multicast mDNS/SAP doesn't cross NAT);
  the VM must sit on the same L2 as the Dante devices.
- At least one Dante device with **AES67 mode enabled** (Dante Controller →
  Device View → AES67 Config → Enabled, reboot device) and a **multicast
  AES67 flow** created on it (Dante Controller → Device View → Create
  multicast flow with the AES67 checkbox).

Checklist for when hardware is available:
1. `hydrad` logs "SAP listener on 239.255.255.255:9875" at startup.
2. Open **Network** in Hydra: Dante devices appear within ~30 s (mDNS).
   The device with AES67 enabled shows **AES67 On** (green); others show
   **AES67 Offline** (orange).
3. The device's multicast flow appears under Streams with name, channel
   count, encoding (L24) and multicast address. `hydrad` logs
   "AES67 stream announced: …".
4. Toggle subscribe: `hydrad` logs "AES67 RX joined …" and the stream's
   channels appear as grid sources.
5. Feed audio into the Dante device's inputs; patch stream ch → speaker
   device in the grid. **You hear network audio**, meters move.
6. Stability: leave it running 10+ minutes — no clicks (ring + servo absorb
   network jitter and clock offset; reception needs no PTP).
7. Re-bind: reboot the Dante device — the stream disappears (SAP timeout
   ≤ 10 min or deletion) and re-binds automatically when re-announced.

**Phase 4 is done when:** audio from a Dante device (in AES67 mode) plays
through the Hydra grid.

### Phase 6 test — channel strips (Logic-style)

1. On the VM, install any free VST3 effect (e.g. TAL-Reverb-4) into
   `/Library/Audio/Plug-Ins/VST3`. Restart `hydrad` — the log shows
   "VST scan: N audio-effect class(es)".
2. Play music into the backplane and patch **In 1/2 → speaker device 1/2**
   (you hear it dry).
3. Select the In 1 cell. The side panel is the **channel strip**: toggle
   **Stereo** (pairs In 1-2), click **Insert…**, search the plugin by name,
   select it.
4. The slot turns indigo. **Click it** → the plugin's editor window opens;
   tweak parameters and hear the change live on the stereo pair.
5. ✕ on the slot removes the effect (audio returns dry instantly).
   **Trim** adjusts the channel's input gain before the inserts.

**Phase 6 is done when:** adding a plugin to a channel strip audibly
processes everything that source feeds, with the editor working live.

Note: connections persist across daemon restarts
(`~/Library/Application Support/Hydra/matrix.json`); used devices persist in
`devices.json`.

## Roadmap

Phase 2: grid engine (IOProc + patch matrix with per-connection gain) →
2b: physical devices + ASRC → 3: per-app capture → 4: AES67 RX → 5: PTP + AES67 TX →
6: VST3 → 7: scenes, robustness, polish. Details in the foundation document, Section 10.

## License

GPL-3.0 — see [`LICENSE`](LICENSE). Third-party components and their licenses
are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The Steinberg
VST3 SDK is fetched by `Scripts/fetch_vst3sdk.sh` (GPLv3 option) and the NDI
runtime is loaded at run time from the user's own install — neither is
committed to this repository.
