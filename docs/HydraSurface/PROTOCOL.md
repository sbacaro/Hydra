# Functional spec — HiQnet + HUI

Only the protocol facts the code needs (formats, IDs, ports). Everything is
**big‑endian** unless noted. This is interface/interoperability information.

## Transport

- **HiQnet:** TCP, port **3804**. **The direction is REVERSED:** the **bridge is the
  server** (listens on 3804) and **the console is the one that connects**. Sequence:
  1. the bridge sends a **DiscoInfo over UDP/3804 broadcast** (an invite); the source
     IP of the datagram is the bridge's address;
  2. on receiving the invite, **the console dials back over TCP/3804** to that IP.

  Confirmed against a **Si Expression 3** (2026‑06‑27): the console answers `ping`
  but **silently drops** any TCP `connect()` on 3804 — it is not a server. Also
  documented by the Mixing Station project
  (<https://dev-core.org/ms-docs/mixers/soundcraft/hiqnet/>).

  **Requirements:** Mac and console on the **same /24**, **broadcast allowed**, and in
  the console's `HIQNET` menu the app's device must have **ALL** access (no
  access‑control blocking it). The console talks to **one app at a time** — close
  ViSi Remote first.
- **Meter:** UDP, port **3333** (dispatched to registered IPs; a separate sub‑protocol).
- **HUI:** serial MIDI 31250 (DAW side), here over a virtual/IAC MIDI port.

## HiQnet — header (25 bytes)

| off | len | field |
|----:|----:|-------|
| 0 | 1 | version (typ. `0x02`) |
| 1 | 1 | headerLen (≥25) |
| 2 | 4 | messageLen (total) — use to frame within the stream |
| 6 | 2 | source device |
| 8 | 4 | source VD(1)+object(3) |
| 12 | 2 | dest device |
| 14 | 4 | dest VD(1)+object(3) |
| 18 | 2 | messageID |
| 20 | 2 | flags |
| 22 | 1 | hopCount (start at `0x05`) |
| 23 | 2 | sequenceNumber |

Address = `device(2).vd(1).object(3)` (6 bytes).

### Message IDs (subset used)
`0x0008` Hello · `0x0100` MultiParamSet (console→us: notification) ·
`0x0103` MultiParamGet · `0x010F` MultiParamSubscribe · `0x0113` ParameterSubscribeAll ·
`0x0114` ParameterUnsubscribeAll · `0x011A` GetVDList.

### Flags
`0x0004` INFO (set = carries data) · `0x0008` ERROR · `0x0040` MULTIPART · `0x0100` SESSION.

### Data types (1 type byte + value)
`0` BYTE · `1` UBYTE · `2` WORD · `3` UWORD · `4` LONG · `5` ULONG · `6` FLOAT32 ·
`7` FLOAT64 · `8` BLOCK(`len:U16`+bytes) · `9` STRING(`len:U16`+UTF‑16BE) · `10/11` (U)LONG64.

### Bodies
- **MultiParamSet `0x0100`:** `paramCount:U16` then N× `paramID:U16` + typed value.
- **ParameterSubscribeAll `0x0113`:** `devAddr:U16` + `vdObject:4` + `subType:U8` +
  `sensorRate:U16` + `subFlags:U16`.
- **MultiParamSubscribe `0x010F`:** `subCount:U16` then N× 16‑byte record:
  `pubParamID:U16` + `subType:U8` + `subAddr:6` + `subParamID:U16` + `rsv0:U8` + `rsv1:U16`
  + `sensorRate:U16`.
- **GetVDList `0x011A`:** `strLen:U16` + UTF‑16BE path.

## Surface — paths and parameter IDs

Each channel strip is a "slot", addressable by a HiQnet path:
```
CS\Coordinator\UI\FaderBay\Slot{NN}\{Fader|OnSw|SoloSw|SelSw}
```
(`NN` = 01..30 on the Si Expression 3. Note: `Fader` may appear without the `CS\`
prefix.) Each slot's channel comes from `SLOTS_CTL.SLOT_ASSIGNMENTS` (banking/layers).

### Parameters (paramID = the object's local SV ID)

**Fader (GFAD):**
`FADER_UBYTE_VALUE 0x0D` (read 0..255) · `MOTOR_UBYTE_VALUE 0x0E` (write 0..255) ·
`FADER_VALUE 0x0F` · `MOTOR_VALUE 0x10` · `GLOW_COLOUR 0x0A` (RGB LED) · `FADER_MODE 0x05`.

**Switch (TLSW — OnSw/SoloSw/SelSw):**
`PRESSED 0x05` · `RELEASED 0x06` · `SWITCH_STATUS 0x0F` (state/LED) ·
`LED_OUTPUT_COLOUR 0x12`.

**Scribble (CH_LCD):** `CHANNEL_NAME 0x06` · `TEXT 0x09` · `LED_COLOUR_OUTPUT 0x05`.

**Banking (SLOTS_CTL):** `CURRENT_SLOT_SEL 0x24` · `SLOT_ASSIGNMENTS 0x27`.

## HUI (DAW side)

- **Ping/keep‑alive:** host→surface `90 00 00`, surface→host `90 00 7F`. Pro Tools'
  "online" criterion is to **keep receiving HUI from the surface**; so the surface must
  **emit `90 00 7F` continuously (~2×/s)** as a heartbeat, even without receiving a ping.
- **Fader (14‑bit):** `B0 0z hi` + `B0 2z lo`, `z` = strip 0..7, value `(hi<<7)|lo`, 0..0x3FFF.
- **Switch/LED:** zone‑select + port pair. **Host→surface (LED):** CC `0x0C`/`0x2C`.
  **Surface→host (press):** CC `0x0F`/`0x2F`. Port in the low 3 bits, `0x40` = on.
  Zones 0..7 = the 8 strips; ports: 1=select, 2=mute, 3=solo.
- **VU:** `A0 0y sv` (Poly Key Pressure), `y`=strip, `sv` low nibble = level 0..0xC.
- **Scribble 4‑char:** `F0 00 00 66 05 00 10 yy c0 c1 c2 c3 F7`, `yy`=strip (0..7).

### Fader scale
`FADER_UBYTE`/`MOTOR_UBYTE` (0..255) ↔ HUI 14‑bit:
`hui = round(ub*0x3FFF/255)`, `ub = round(v14*255/0x3FFF)` (exact round‑trip across all 256 values).
