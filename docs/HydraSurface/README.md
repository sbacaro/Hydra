# HydraSurface

Swift 6 core of a **control‑surface** bridge between **Soundcraft Si** consoles
(via HiQnet, over the network) and DAWs that speak **Mackie HUI** (Pro Tools, etc.)
over MIDI. No UI — designed to be consumed by a SwiftUI app (e.g. **Hydra**) or run
standalone.

HiQnet is **inbound**: the bridge sends an invite over UDP broadcast and the console
dials back.

```
[HydraSurface] ──DiscoInfo (broadcast UDP/3804, invite)──►  Si console
Si console     ──connects back (TCP/3804)───────────────►  [HydraSurface] ──HUI/MIDI (IAC)──► DAW
               ◄──── MultiParamSet ──                     ── faders/mutes/… ────►
```

## Scope and notice

This package is an **original, independent reimplementation**, written for
**interoperability** (letting the console act as a control surface for a DAW).

- It does **not** contain, distribute or depend on any third‑party firmware,
  binaries, disassembly or SDK. Only original code and protocol facts (formats,
  IDs, ports).
- It is **not affiliated** with Harman, Soundcraft, Avid/Pro Tools or Mackie, nor
  endorsed by them. "Soundcraft", "Si Expression", "HiQnet", "HUI", "Pro Tools" and
  "Mackie" are trademarks of their respective owners, used here only in a
  **nominative/descriptive** sense to indicate compatibility.

## Contents

| File | Role |
|------|------|
| `HiQnet.swift` | HiQnet protocol codec (header, MultiParamSet/Subscribe, types) |
| `HUI.swift` | Mackie HUI codec (faders, switches, ping, VU, scribble) + decoder |
| `SurfaceIDs.swift` | Surface parameter IDs (GFAD/TLSW/CH_LCD/SLOTS) and paths |
| `MIDIBackend.swift` | MIDI abstraction + CoreMIDI implementation (virtual or IAC) |
| `HiQnetClient.swift` | HiQnet/TCP **server** (the console connects back) + UDP meter listener |
| `SurfaceBridge.swift` | engine + **observable API** ready for SwiftUI |
| `docs/PROTOCOL.md` | functional spec (only the facts the code needs) |

The codecs (`HiQnet`, `HUI`, `Surface*`) are **pure and platform‑independent** —
testable anywhere. The I/O (`CoreMIDIBackend`, `HiQnetServer`) is macOS/Apple.

## API for the UI

`SurfaceBridge` is `@MainActor @Observable` — the UI just observes its properties:

```swift
import HydraSurface

@State private var bridge = SurfaceBridge()

// Start (DAW-only mode over IAC, no console yet):
bridge.start(config: .init(midiOutName: "Bus 1", midiInName: "Bus 2"))

// Observable in SwiftUI:
//   bridge.isOnlineToDAW, bridge.heartbeatCount
//   bridge.faders[0..7], bridge.mutes/solos/selects
//   bridge.isConnected (HiQnet), bridge.lastError
```

For the console there is **no IP to configure**. `start(config:)` already opens the
TCP/3804 listener (`startListening()`); the app only needs to send the DiscoInfo
invite over UDP broadcast (the daemon does this) and the console **dials back**.
`bridge.consoleIP` is filled in with the console's IP once it connects. Slot
addresses resolve at run time (GetVDList) or manually via
`setSlotAddress(slot:sub:address:)`.

## Build / use

Standalone:
```bash
swift build
swift test          # runs the codec tests (Swift Testing)
```

Inside Hydra (recommended): add it as a **local package** and list `HydraSurface`
as a dependency of the app target. The module is control‑plane only (MIDI +
network) — it never touches the real‑time audio engine.

## Calibration to‑dos (need a real console on the LAN) — marked `[CALIBRATE]`

1. Confirm **SV‑ID == paramID** (move one control, see the paramID that comes back).
2. **GetVDList**: parse the response → fill in the slot addresses.
3. The bridge's **device address** (Hello vs RequestAddress).
4. **Meters**: decode the UDP 3333 packet (the listener already receives it; the
   layout is still missing).

The **HUI/DAW** side is already testable without a console (heartbeat handshake,
faders, switches).

## License

Intended to be **GPL‑3.0** (to match Hydra). Add the corresponding `LICENSE` file
when integrating. Copyright in this package's code belongs to the author.
