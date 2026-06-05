# Third-Party Notices

Hydra is free software licensed under **GPL-3.0** (see `LICENSE`). It builds on
the following open-source components, which are credited here and in the app's
*About / Acknowledgements* screen.

## BlackHole

- **What:** The virtual audio driver that powers the "Hydra Virtual Soundcard"
  256×256 backplane. Hydra builds a customized BlackHole (channel count, device
  name, and bundle ID changed); all DSP/driver logic is BlackHole's.
- **Author:** Existential Audio Inc. (Devin Roth)
- **Source:** https://github.com/ExistentialAudio/BlackHole
- **License:** GPL-3.0

Renaming the device to "Hydra Virtual Soundcard" is product UX, permitted by the
GPL. The origin of the driver is not hidden: it is BlackHole, credited openly.

## VST3 SDK

- **What:** Plugin hosting — Hydra compiles the SDK's hosting subset
  (module loading, host classes) in the `HydraVST` target to run VST3 effect
  chains in the signal path. The SDK is fetched at build time into
  `ThirdParty/vst3sdk` by `Scripts/fetch_vst3sdk.sh`.
- **Author:** Steinberg Media Technologies GmbH
- **Source:** https://github.com/steinbergmedia/vst3sdk
- **License:** Dual-licensed; Hydra uses the **GPLv3** option (compatible with
  Hydra's GPL-3.0). VST® is a trademark of Steinberg Media Technologies GmbH,
  registered in Europe and other countries.

## NDI (runtime loaded dynamically — never bundled)

- **What:** NDI audio receive/transmit. Hydra's own code (`HydraNDIShim`,
  GPL-3.0) contains only minimal ABI declarations and `dlopen()`s the NDI
  runtime at run time — the DistroAV/OBS pattern.
- **Author:** Vizrt NDI AB. NDI® is a registered trademark of Vizrt NDI AB.
- **License:** The runtime is proprietary and **not GPL-compatible**, so it is
  **never bundled or linked**. Users install it from Vizrt's official
  redistributable (https://ndi.link/NDIRedistV6Apple — the only distribution
  channel the NDI license permits; `vm_install.sh` automates that download).
  Without the runtime, NDI features stay off and everything else works.

## Open standards implemented from scratch (no third-party code)

- **AES67** — audio-over-IP interoperability (SAP/SDP/RTP parsing is Hydra
  code, unit-tested). Dante® is a registered trademark of Audinate Pty Ltd;
  Hydra is not affiliated with or certified by Audinate.
- **OSC 1.0** — remote control protocol; parser is Hydra code, unit-tested.

---

*This file is updated whenever a third-party component is added, per the project
principle: naming devices is UX; hiding the origin of components is not allowed.*
