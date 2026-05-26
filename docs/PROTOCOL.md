# Z-Wave Blind Controller — Inter-Board Protocol

Reverse-engineering notes for a Z-Wave smart blind. Two boards:

- **Control board** — Z-Wave brain. ZM5202 module (Sigma Designs / Silicon Labs
  **SD3502**, Z-Wave 500-series, 8051 core), button, two-color LED, battery power
  section, and a **25PE20VP** (Micron/ST M25PE20, 2 Mbit) SPI flash on the module's
  SPI1 bus.
- **Motor controller board** — drives the motor, reads the magnet + two hall
  sensors for position. Connected to the control board by a 5-pin cable.

The control board (ZM5202, **I²C master**) commands the motor board (**I²C slave
@ 0x0B**) over a **bit-banged I²C bus using SMBus framing**.

> Status: derived entirely from logic-analyzer captures. Field *meanings* marked
> "(hypothesis)" still need confirmation. The transport layer (pinout, I²C, SMBus
> framing, PEC, command codes, direction, position) is confirmed.

---

## Inter-board connector (5-pin)

| Pin | Wire   | ZM5202 pin | Signal | Notes |
|:---:|:-------|:----------:|:-------|:------|
| 1   | —      | GND (1,6,12,16,17) | GND | Ground |
| 2   | Brown  | 13 (GPIO) | **ENABLE / wake** | Master drives high to wake motor board; pulldown, idle low |
| 3   | Red    | 10 (GPIO, alt UART0_RX) | **I²C SDA** | Bit-banged |
| 4   | Orange | 15 (GPIO, alt UART0_TX) | **I²C SCL** | Bit-banged, master-driven; also carries the boot frame (below) |
| 5   | —      | — (raw battery) | **VCC** | Raw battery passed straight through to motor board |

Each signal line: series resistor + shunt cap (RC filter) + 3-pin ESD clamp
(steering diodes to VCC/GND), connected **directly** to the ZM5202 (no buffer,
non-inverting).

---

## Boot frame (ignore for control)

At every power-up, **before** I²C starts, the module emits a fixed async-serial
frame on **orange / pin 15** (which is reconfigured to I²C SCL afterward):

- **19200 baud, 8N1, idle-high, LSB-first**
- Bytes: **`0x42 0x01 0xBD`**  (additive checksum: `0x42+0x01+0xBD = 0x100`)
- One-way, identical every boot, **no reply** on RX.

Interpretation: a boot/version announce on a repurposed UART pin. **Not** part of
the I²C protocol (different checksum scheme, no response). Decorative — ignore it.

Sequence at power-up: rails high → ENABLE high ~29 ms then low → `42 01 BD` on
SCL pin → idle → ENABLE high again → ~70 ms later I²C begins.

---

## I²C / SMBus transport

- **Bus:** bit-banged I²C, ~15 kHz (SCL ≈ 17.5 µs low / 50 µs high, jittery).
- **Master:** ZM5202.  **Slave:** **0x0B** (7-bit).
- **Framing:** SMBus.
  - Block read: `[count] [data…] [PEC]`
  - Read word: `[lo] [hi] [PEC]`
  - Block write: `[cmd] [count] [data…] [PEC]`
- **PEC:** **CRC-8, polynomial 0x07** (SMBus PEC), computed over address +
  command + data. Validates on clean transactions.
- **Endianness:** payloads are **big-endian (MSB first)**, despite SMBus's nominal
  little-endian word order. Parse all multi-byte values MSB-first.

---

## Command / register map

| Cmd  | Access | Type        | Observed values | Meaning |
|:----:|:------:|:------------|:----------------|:--------|
| 0x9B | R      | block(16) ASCII | `"5120199A12t     "` | Device ID / serial string |
| 0xA1 | R      | block(4) u32 | `0` | Counter/status (always 0 so far) |
| 0xA3 | R      | block(4) u32 | `576` (constant) | **Full travel range** — 0 = open … 576 = closed |
| 0xA4 | R      | block(4) **i32** | `−6 … 583` | **Live absolute position** (signed, non-volatile). 0 = open, ~576/583 = closed |
| 0x7A | R      | word(2)     | see status table | **Motion / stop status** |
| 0x8B | R      | word(2)     | `~0x26xx–0x27xx` | **Analog telemetry, read once per move.** Non-monotonic (dropped `0x2770`→`0x2718` within a session) → not a counter. Sits on PMBus `READ_VOUT` code; likely battery/motor voltage. Scaling TBD |
| 0xD1 | W (Process Call?) | block(4) i32 | `+1`, `−1`, signed deltas | **Move command** (see below) |

Notes:
- `0xA4` **persists across power cycles** — boots read the last parked position
  (e.g. −6). The board does **not** re-home on power-up.
- One `0xD1` write decoded as SMBus "Process call" — believed to be a bit-bang
  timing artifact, not a real read-back. To verify.
- The PMBus angle: command codes 0x9B/0xA1/0xA3/0xA4/0x7A/0x8B collide with
  standard PMBus codes (MFR_REVISION, MFR_VIN_MAX, etc.), and an SMBus/PMBus
  decoder validates the framing — but the **payloads are motor data, not power
  telemetry**, and 0xD1 is in the PMBus manufacturer-specific range. So it's a
  **PMBus/SMBus-derived framework repurposed for motor control**, not real PMBus.

### 0xD1 — Move command

Signed value. Two reserved sentinels run to a physical limit; any other value is a
**relative move** by that many position counts.

| Value (i32)        | Effect |
|:-------------------|:-------|
| `0x00000001` (+1)  | **Close** — run to top/max limit (≈ 583), stops `0x7A = 0x01C2` |
| `0xFFFFFFFF` (−1)  | **Open** — run to bottom/min limit (≈ −6), stops `0x7A = 0x01C4` |
| other N (signed)   | **Relative move** by N counts. Negative = toward open (count ↓), positive = toward close (count ↑). Stops at target, `0x7A = 0x01C0`. |

Sign convention is consistent: **negative = open direction, positive = close
direction.** Motor coasts a few counts past the commanded delta. A button press
sends a `±1` sentinel (full traverse, alternating direction).

The host reads `0xA4`, computes the count delta to the target, and writes it to
`0xD1`. **Percent maps linearly** over the `0xA3 = 576` range:

```
position = (100 − percent_open) / 100 × 576      # 0% = closed/576, 100% = open/0
```

Confirmed (`100_25_75_0.sal`, start open ≈ 0):

| Target      | Expected pos | D1 written          | End pos | Stop   |
|:------------|:-------------|:--------------------|:--------|:-------|
| 25% open    | 432          | `+426` (Δ to ~432)  | 427     | `0x01C0` target |
| 75% open    | 144          | `−282` (Δ 427→145)  | 142     | `0x01C0` target |
| 0% (closed) | 576          | `+1` (sentinel)     | 582     | `0x01C2` limit |

The `−282` delta vs. the ideal `−283` (427→144) is the definitive proof that `0xD1`
is a **signed relative move** in counts (motor coasts ~1–5 counts past). Also seen
in `percent_based_moves.sal` (`−264`: ~576→312; `−120`: 312→188; `+1`: →579 close).

> Note: `0xD1` decodes as an SMBus **Process Call** (write+read) in the percent
> capture but as **block-write** in the button capture. May be a genuine
> write+readback or a bit-bang timing artifact — unresolved.

### 0x7A — Status word

| Value                         | State |
|:------------------------------|:------|
| `0x0080`                      | Idle / ready (just after enable) |
| `0x0000`,`0x0040`,`0x0140`,`0x0142` | Moving (low bits vary by move type/phase) |
| `0x01C0`                      | **Stopped — reached commanded target** (partial move) |
| `0x01C2`                      | **Stopped at top/max limit** (closed, ≈ 583) |
| `0x01C4`                      | **Stopped at bottom/min limit** (open, ≈ −6) |

Stopped codes are the reliable signal; the low nibble is the stop reason:
`0` = target reached, `2` = top limit (closed), `4` = bottom limit (open).

### Position / travel

- Range: **≈ −6 (fully open) … 583 (fully closed)**. Higher count = more closed.
- `0xA3 = 576` = calibrated full travel, used as the 0–100% range (0 = open,
  576 = closed). Hard stop overshoots slightly to ≈ 583.

---

## Typical transaction flow

Power-up / status poll:
```
9B → ID string
A1 → 0
A3 → 576
A4 → <current position>
```

Move + monitor loop (per button press / command):
```
D1 = ±1 (open/close) or a signed count delta (partial positioning)
loop:
  A4 → position    # watch it ramp toward the target/limit
  7A → status      # moving codes while in motion
until 7A = 0x01C0 (target) / 0x01C2 (closed limit) / 0x01C4 (open limit)
8B → counter       # read once after move completes
```

---

## Driving the motor board yourself (as master)

You can bypass the Z-Wave side entirely:

1. Wire an I²C master (Pi/Arduino) to **SDA = red/pin 3**, **SCL = orange/pin 4**,
   **GND = pin 1**. Power the motor board from **VCC = pin 5** (raw battery).
2. Raise **ENABLE (brown / pin 2)** high, wait ~30 ms.
3. Talk SMBus to **0x0B** at ~15 kHz with **CRC-8 (poly 0x07) PEC**.
4. Issue `0xD1`: `0xFFFFFFFF` (−1) = open, `0x00000001` (+1) = close, or a signed
   count delta for partial positioning. Poll `0x7A` until a stop code
   (`0x01C0`/`0x01C2`/`0x01C4`) appears, and/or read `0xA4` for live position.
5. **Retry on PEC failure** — the bit-banged bus glitches occasionally, especially
   around power transitions. The real master tolerates this.

---

## Open items

- [x] ~~Confirm `0xA3 = 576` maps percent linearly~~ — confirmed (`100_25_75_0.sal`):
      `position = (100 − %open)/100 × 576`.
- [ ] Identify `0x8B` telemetry units/scaling (likely voltage) and what it measures.
- [ ] Confirm `0x7A` moving low-bit meanings — `0x0100` bit appears tied to limit-runs
      (sentinel `±1`) vs targeted moves, but varies between captures.
- [ ] Determine if `0xD1` is genuinely an SMBus Process Call and returns data.
- [ ] Verify positive relative deltas behave symmetrically (only negative observed).
- [ ] Probe standard PMBus codes (`0x98` PMBUS_REVISION, `0x99` MFR_ID,
      `0x01` OPERATION, `0x03` CLEAR_FAULTS) — does a real PMBus stack underlie it,
      and is `0x01` an alternate enable?
- [ ] Map `0xA4` counts to physical travel (counts per revolution / per mm).

---

## Captures

In `../csz1-control-board/captures/`:

- `up_down.sal` — full open/close via button (run-to-limit, `0xD1 = ±1`).
- `percent_based_moves.sal` — two partial (percent) moves then close.
- `100_25_75_0.sal` — open → 25% → 75% → 0% (closed); confirms linear percent mapping.

A logic-analyzer MCP server is configured for loading/analyzing these `.sal` files.

## Hardware reference

- **MCU:** SD3502 (Z-Wave 500-series, 8051). Firmware in internal flash; debug via
  Sigma proprietary serial programming interface (not SWD), likely lock-protected.
- **Module:** ZM5202 (12.5×13.6 mm), pins 7/8/9 = SPI1 MISO/SCK/MOSI to the 25PE20 flash.
- **External flash:** 25PE20VP, 256 KB SPI — OTA image staging / NVM. Dumped and
  analyzed separately; see [`HARDWARE.md`](HARDWARE.md).
