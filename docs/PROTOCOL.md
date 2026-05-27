# CSZ1 ↔ Killer Bee — Inter-Board Protocol

The cross-component wire protocol inside the
[Springs Window Fashions Z-Wave blind](../README.md). The two boards on the bus:

- **[CSZ1 controller](../csz1-control-board/README.md)** — the Z-Wave brain. ZM5202
  module (Sigma Designs / Silicon Labs **SD3502**, Z-Wave 500-series, 8051 core).
  It is the **I²C master** on this bus.
- **[Killer Bee motor board](../killer-bee-motor-controller/README.md)** — drives
  the motor, reads the magnet + two hall sensors for position. Connected to the
  CSZ1 by a 5-pin cable. Built on an **ATmega168P**; its dumped firmware confirms
  the slave side of this protocol (slave address, TWI state machine, register
  handling).

The CSZ1 (ZM5202, **I²C master**) commands the Killer Bee (**I²C slave @ 0x0B**)
over a **bit-banged I²C bus using SMBus framing**. (The other link in the system —
the VCZ1 remote to the CSZ1 — is Z-Wave RF, not this bus.)

> Status: the transport layer (pinout, I²C, SMBus framing, PEC, direction,
> position) is confirmed from captures **and from both firmwares**. The full
> command/register map is decoded from the motor-board (slave) firmware
> (`../killer-bee-motor-controller/README.md`); the **master side is now also decoded from the SD3502 control
> firmware** (see *Master-side firmware* below) — the bit-bang I²C driver, the
> address/PEC, and the read/write/move command builders all match. Codes marked ⬤
> were also exercised in captures. Field *meanings* marked "(hypothesis)" still need
> confirmation.

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
  **Master-side (SD3502 firmware) confirms the bit-bang:** open-drain on 8051
  **Port 3 — SDA = P3.4, SCL = P3.5** (so connector red/pin 3 = SDA = die P3.4,
  orange/pin 4 = SCL = die P3.5). SCL release-high spins polling the `P3.5`
  readback until the slave lets it rise — i.e. the master **honours the slave's
  clock-stretching** (`i2c_scl_release_high_wait`). The jittery rate is a
  byproduct of the software loop, not a fixed divisor.
- **Master:** ZM5202.  **Slave address:** **0x0B** (7-bit) → write byte `0x16`,
  read byte `0x17`. (Slave firmware: `TWAR = 0x16`. Master firmware: the START
  routine `i2c_start_write_addr16` loads exactly `0x16`; reads send `0x17` — both
  confirmed.)
- **Bit rate tolerance:** the slave is a hardware TWI peripheral on an 8 MHz
  ATmega168P; it clock-stretches and is insensitive to the master's exact rate.
- **Endianness:** multi-byte payloads are **big-endian (MSB first)**, despite
  SMBus's nominal little-endian word order. Parse all multi-byte values MSB-first.

### Notation

`S` = START, `Sr` = repeated START, `P` = STOP, `Wr`=`0x16`, `Rd`=`0x17`.
`[x]` = one byte. **Bold** = driven by the slave; the rest by the master.

### Frame formats (byte-by-byte)

These are the SMBus protocols the master actually uses, with the exact byte
sequence on the wire. `N` is the block byte count.

**Block read** (used by `0x9B`, `0xA1`, `0xA3`, `0xA4`):
```
S Wr [cmd] Sr Rd  **[N] [d0] [d1] … [d(N-1)] [PEC]**  P
                    ^count ^big-endian payload (d0 = MSB)   ^slave-computed
```

**Read word** (used by `0x7A`, `0x8B`) — SMBus Read Word, **no count byte**:
```
S Wr [cmd] Sr Rd  **[lo] [hi] [PEC]**  P
```
Payload is big-endian on the wire for this device: the first data byte is the
**high** byte of the 16-bit value (parse MSB-first regardless of SMBus's
little-endian convention).

**Block write** (used by `0xD1`):
```
S Wr [cmd] [N] [d0] [d1] … [d(N-1)] [PEC]  P
            ^count ^big-endian payload (d0 = MSB)
```

### PEC — CRC-8/SMBus (firmware-confirmed)

- **Algorithm:** CRC-8, **polynomial `0x07`**, **init `0x00`**, no reflection,
  no final XOR — the standard SMBus PEC.
- **Coverage:** every byte of the transaction *including the address bytes and
  the R/W bit*, in transmission order. Concretely:
  - block/word **read**: `Wr, cmd, Rd, <count if block>, d0…d(N-1)`
  - block **write**: `Wr, cmd, count, d0…d(N-1)`
- **Slave implementation (confirmed in the ATmega168P firmware):** table-driven.
  The TWI ISR folds each received byte into a running PEC,
  `pec = crc8_table[pec ^ byte]`, using a 256-byte CRC-8/SMBus table in flash and
  the accumulator `twi_pec` (= `twi_buf[4]`). On a read the same accumulator is
  clocked out as the trailing PEC byte. See `../killer-bee-motor-controller/README.md`
  (`crc8_smbus_table` @ `code:0034`, `crc8_pec_lookup` @ `code:0CCC`).
- **Master implementation (confirmed in the SD3502 firmware):** *bit-serial*, not
  table-driven. `smbus_pec_crc8_update` folds each byte with
  `acc ^= byte; repeat 8×: acc = (acc & 0x80) ? (acc<<1)^0x07 : acc<<1`, accumulator
  in internal RAM `0x65`, initialised to 0 by the START routine. `i2c_send_byte_pec`
  calls it for every transmitted byte; the trailing byte on a read is clocked out as
  the accumulated PEC. Different code from the slave's table version, **same result**.
- **Reference table:** `00 07 0E 09 1C 1B 12 15 …` (first 8 entries).
- **Behavior:** the slave NAKs / flags `twi_parse_status` on a bad PEC; the
  bit-banged master occasionally glitches a transaction, so **retry on PEC error**
  (the real master does).

### Worked examples

The PEC definition above is **verified against the captures**: re-deriving CRC-8
(poly 0x07, init 0) over `[Wr, cmd, (Rd), count?, data…]` reproduces **every** PEC
byte in `up_down.csv` (26/26 frames, including block reads, read words, and the
`0xD1` block write). PEC bytes below are computed the same way.

Read live position `0xA4` (block read of an `i32`, value `+576` = closed):
```
S 16 A4 Sr 17  **04 00 00 02 40 20**  P
            └N┘ └─ 0x00000240 = 576, MSB first ─┘ └PEC
PEC = crc8( 16 A4 17 04 00 00 02 40 ) = 0x20
```

Read status word `0x7A` (read word, value `0x01C0` = stopped at target):
```
S 16 7A Sr 17  **01 C0 38**  P
PEC = crc8( 16 7A 17 01 C0 ) = 0x38
```

Move command `0xD1` (block write of an `i32`; `-1` = open to bottom limit):
```
S 16 D1 04 FF FF FF FF 63  P
        └N┘ └─ 0xFFFFFFFF = -1, MSB first ─┘ └PEC
PEC = crc8( 16 D1 04 FF FF FF FF ) = 0x63
```

---

## Command / register map

| Cmd  | Access | Type        | Observed values | Meaning |
|:----:|:------:|:------------|:----------------|:--------|
| 0x9B | R      | block(16) ASCII | `"5120199A12t     "` | Device ID / serial string |
| 0xA1 | R      | block(4) u32 | `0` | Counter/status (always 0 so far) |
| 0xA3 | R      | block(4) u32 | `576` (constant) | **Full travel range** — 0 = open … 576 = closed |
| 0xA4 | R      | block(4) **i32** | `−6 … 583` | **Live absolute position** (signed, non-volatile). 0 = open, ~576/583 = closed |
| 0x7A | R      | word(2)     | see status table | **Motion / stop status** |
| 0x8B | R      | word(2)     | `~0x26xx–0x27xx` | **Analog telemetry, read once per move.** Non-monotonic → not a counter. Firmware computes `(u16@0x0319 * gain@0x02b7) >> 13 ± offset@0x02b9` (Q13 linear cal); `0x8080` = not-ready sentinel. Units TBD (cal constants are runtime SRAM) — see Full read map |
| 0xD1 | W (Process Call?) | block(4) i32 | `+1`, `−1`, signed deltas | **Move command** (see below) |

The table above is what the captures exercised. The firmware actually implements
many more codes — the **full map below is decoded directly from the two dispatchers**
(`twi_read_response_dispatch` @ `code:00f2`, `twi_write_cmd_dispatch` @ `code:0263`).
The wire code *is* the internal opcode (no remap).

#### Full read map (reg → response), from firmware

The opcode is `frame[5]`; each case validates the request then stages response
bytes. Codes marked ⬤ were also seen in captures.

| Reg | ⬤ | Response | Source (firmware) |
|:--:|:--:|:--|:--|
| `0x10` | | block | `build_response_10` |
| `0x7A` | ⬤ | word (2B) | status/limits word from `motor_state` (`get_status_word_7a`) |
| `0x8B` | ⬤ | word (2B) | telemetry: `(u16@0x0319 * gain@0x02b7) >> 13 ± signed offset@0x02b9` (`build_telemetry_8b`); `0x8080` = not-ready. `0x0319` lives in the position/motion cluster (the "ADC-derived" label is **unconfirmed**); units TBD |
| `0x96` | | block (11B) | internal buffer copy |
| `0x98` | | block | SRAM buffer @ `0x023B`, length = `[0x023B]` |
| `0x99` `0x9D` `0x9E` | | block | internal SRAM buffers (`copy_block_to_response`) |
| `0x9A` | | word (2B) | `eeprom_read_u16` (config value) |
| `0x9B` | ⬤ | block | `device_id_str` (length `device_id_len`) — serial string |
| `0x9F` | | 2B | `motor_state[0x27..0x28]` |
| `0xA1` | ⬤ | u32 | **EEPROM[0x70] = 0** (counter/status) |
| `0xA2` | | u32 | **EEPROM[0x78] = 117** (calibration constant) |
| `0xA3` | ⬤ | u32 | **EEPROM[0x74] = 576** (full travel range) |
| `0xA4` | ⬤ | i32 | **SRAM[0x0305]** = live absolute position (signed) |
| `0xB0` | | word (2B) | `compute_response_b0` (32-bit math result) |

> `0xA1/0xA2/0xA3` are the three values from the EEPROM `int32[4]` calibration
> block at `0x70` (see `../killer-bee-motor-controller/README.md`); `0xA4` is the live RAM position. So
> `0xA3` (full travel = 576) is a stored calibration constant, while `0xA4` moves.

#### Full write map (reg → action), from firmware

Opcode is `frame[5]`. **Many write codes are gated on an internal "calibrated/armed"
flag (`GPIOR1` bit `0x10`)** and silently no-op when it is clear — i.e. they are
provisioning/calibration commands, not normal runtime controls. Length checks read
the declared block byte-count.

| Reg | ⬤ | Len | Action (firmware) |
|:--:|:--:|:--:|:--|
| `0x00` | | 2 | **Control/magic**: a staged magic word selects `Reset()` (`0x59xx`) or **enters the I²C firmware-update bootloader** (`0x90xx` → `twi_bootloader_loop`, never returns); also toggles the calibrated flag. See *Firmware-update bootloader* below |
| `0x01` | | | **Arm motion** — `GPIOR0|=0x80`, `GPIOR1|=0x08` (+ signed limit adjust) |
| `0x02` | | | write `motor_state[0x0D]` |
| `0x04` | | | stage value, **clamp to ≤100** (a percent), write `motor_state` |
| `0x05` `0x07` `0x08` | | | increment a `motor_state` counter byte |
| `0x06` | | | `GPIOR0|=0x40`; `motor_state[0x10] = 2` |
| `0x09` | | | block setup over SRAM `0x2F9..0x301` (only when not busy) |
| `0x7A` | | | register write (`twi_cmd_7a_write`) |
| `0x89` | | | multi-byte write (`twi_cmd_89_write`) |
| `0x8C` | | | `twi_cmd_8c_write` |
| `0x8D` | | | write `motor_state[0x2B]` region |
| `0x9A` `0x9B` | | 0x13 | *calibrated*: copy 19-byte payload into `device_id_str` + target write |
| `0x9D` | | 9 | *calibrated*: clamp `motor_state[0x54]`≤6, stage 3-byte @ `0x0323` |
| `0x9E` | | 0x12 | *calibrated*: clamp `[0x02DA]`≤0x0F, stage 2-byte @ `0x02DB` |
| `0xA1` `0xA2` `0xA3` `0xB0` | | | *calibrated*: commit `motor_state` fields |
| `0xC0` | | 6 | *calibrated*: **raw EEPROM byte write** (addr = payload[7:8], data = payload[9]) — a factory/calibration backdoor; else falls to the `0xD0` path |
| `0xD0` | | | **spawn motion** (`motor_direction_setup`); `GPIOR0|=0x10`, `GPIOR1&=0xFB` |
| `0xD1` | ⬤ | 4 | **MOVE** — i32 delta (`twi_cmd_D1_move`); see below |
| `0xD2` | ◐ | 4 | move setup, sibling of `0xD1` (target = 600; `twi_cmd_d2_move_setup`). **The master *does* emit this**: `build_move_cmd_D1_D2` picks `0xD2` instead of `0xD1` when mode flag `XDATA[0x2522]` is set (not yet seen in our captures — ◐). |

> `0x03` is **not** handled. Unknown opcodes (and length/PEC failures) set
> `twi_parse_status` to a nonzero error code. The gated calibration commands
> (`0x9A/0x9B/0x9D/0x9E/0xA1/0xA2/0xA3/0xB0/0xC0`) only act after the calibrated
> flag is set — normal positioning uses just `0xD1` + the read codes.

### Firmware-update bootloader (write `0x00`, magic `0x90xx`)

Write opcode `0x00` with the magic word `0x90xx` does not return — it jumps into an
**I²C/TWI-resident firmware-update bootloader** (`twi_bootloader_loop` @ `code:1c00`)
that reconfigures peripherals and then services the host entirely over the same I²C
slave interface. After entry, a command byte (`motor_state+0x24`) selects:

| Boot cmd | Routine (`code:`) | Action |
|:--:|:--|:--|
| `0x02` | `twi_bootloader_build_status_frame` (`1ce6`) | return an 0x89-byte status frame (header + 0x80-byte data block, XOR-checksummed) |
| `0x04` | `twi_bootloader_flash_write_exec` (`1d40`) | verify the buffered block and **program it into flash via `spm`** |

Per-byte transfers are handled by `twi_bootloader_byte_handler` (`1c5e`); a 16-bit
inactivity counter disarms the session on timeout. **Full download/program frame
layout (addressing, block size, checksum placement) is not yet mapped** — this is a
candidate for the next capture/trace session. Security note: the path into program
flash is gated only by the `0x90xx` magic word over I²C. See `../killer-bee-motor-controller/README.md` →
*I²C firmware-update bootloader* for the firmware-side detail.

Notes:
- `0xA4` **persists across power cycles** — boots read the last parked position
  (e.g. −6). The board does **not** re-home on power-up.
- One `0xD1` write decoded as SMBus "Process call" — **resolved: it is a bit-bang
  timing artifact, not a real read-back.** The master's move builder
  (`build_move_cmd_D1_D2`) calls `smbus_write_transaction` and never reads back; it
  is a plain block write.
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
> capture but as **block-write** in the button capture. **Resolved from the master
> firmware: it is always a block write** — `build_move_cmd_D1_D2` stages
> `[opcode][count=4][i32]` and calls `smbus_write_transaction` with no read phase.
> The "process call" decode is a bit-bang timing artifact.

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

## Master-side firmware (SD3502 control board)

The Z-Wave control firmware (`sd3502_internal.bin`, banked 8051) drives this protocol
as the I²C master. It ships as the stock Sigma/SiLabs SDK image (no strings, ~960
functions, everything was `FUN_*`); the I²C/SMBus master lives mostly in **BANK1** and
is now named in Ghidra. The wire facts above were re-derived from it independently of
the captures and the slave firmware — and they match.

**Transport / framing layer:**

| Function (Ghidra) | Role |
|:--|:--|
| `i2c_sda_high` / `i2c_sda_low` / `i2c_sda_drive_prep` | drive **SDA = P3.4** (open-drain) |
| `i2c_scl_release_high_wait` / `i2c_scl_low` | drive **SCL = P3.5**; release-high spins on the `P3.5` readback → **honours slave clock-stretch** |
| `i2c_read_bit` / `i2c_read_ack_arbitration` / `i2c_delay_loop` | sample SDA/ACK, bit timing |
| `i2c_start_write_addr16` | START + write-addr `0x16`; inits PEC=0 |
| `i2c_send_byte_pec` | shift out one byte MSB-first, fold into PEC |
| `smbus_pec_crc8_update` | **PEC**: bit-serial CRC-8 poly `0x07`, acc `IRAM 0x65` |
| `smbus_build_descriptor` | stage transfer descriptor at `XDATA 0x298c` |

**Frame buffers (XDATA):** TX = `0x278e`[opcode] `0x278f`[count/data] `0x2790…`[payload];
RX response staged at `0x278f…` (big-endian, first byte = MSB).

**Command layer** (each wraps `smbus_read_transaction` / `smbus_write_transaction`;
the last numeric arg is the byte count, see those functions' comments):

| Function (Ghidra) | Wire op | Notes |
|:--|:--|:--|
| `smbus_read_reg_generic` | (any) | block/word read core, returns first data byte |
| `read_reg_7A_status` | R `0x7A` | status word (2B) |
| `read_reg_8B_telemetry` | R `0x8B` | telemetry word (2B); substitutes cached `XDATA 0x1240/41` on the `0x8080` not-ready sentinel |
| `read_reg_9B_devid` | R `0x9B` | 16-byte ID string, compared against a stored copy |
| `read_reg_A3_travel` | R `0xA3` | u32 full-travel range → `XDATA 0x124c` |
| `read_reg_A4_position` | R `0xA4` | i32 live position → `XDATA 0x1244` |
| `write_reg_7A` | W `0x7A` | word write (`0xFFFF`) |
| `write_reg_D0_motion` | W `0xD0` | word write (`0x0000`) — spawn motion |
| `build_move_cmd_D1_D2` | W `0xD1`/`0xD2` | **MOVE**: count 4, i32 delta MSB-first from `XDATA 0x250b`; opcode `0xD1`, or `0xD2` when `XDATA[0x2522]` set |

> The master reads `0x9B`/`0xA3`/`0xA4`/`0x7A`/`0x8B` and writes `0x7A`/`0xD0`/`0xD1`(/`0xD2`).
> It never reads back after a write (no SMBus process call). The descriptor args passed
> into the read/write cores are a response-buffer pointer + length supplied by the I²C
> stack.

## Open items

- [x] ~~Confirm `0xA3 = 576` maps percent linearly~~ — confirmed (`100_25_75_0.sal`):
      `position = (100 − %open)/100 × 576`.
- [~] `0x8B` telemetry — **transfer function resolved, units open**. Firmware:
      `(u16@0x0319 * gain@0x02b7) >> 13 ± signed offset@0x02b9`, `0x8080` = not-ready.
      The cal constants are runtime SRAM (no flash initializer), so converting to
      physical units needs a bench read of `0x02b7`/`0x02b9` (or the EEPROM block that
      seeds them). The "voltage/ADC" guess is **unconfirmed** — `0x0319` sits in the
      position/motion cluster, not the ADC accumulator.
- [ ] Map the bootloader (`0x00`/`0x90xx`) download+program frame layout.
- [ ] Confirm `0x7A` moving low-bit meanings — `0x0100` bit appears tied to limit-runs
      (sentinel `±1`) vs targeted moves, but varies between captures.
- [x] ~~Determine if `0xD1` is genuinely an SMBus Process Call and returns data.~~ —
      **no.** Master `build_move_cmd_D1_D2` does a pure block write, no read-back.
- [~] Verify positive relative deltas behave symmetrically (only negative observed in
      captures). The master builds a signed i32 delta for either direction
      (`build_move_cmd_D1_D2`, payload from `XDATA[0x250b]`), so symmetry is expected;
      still want a positive-delta capture to confirm on the wire.
- [ ] Identify what sets master mode flag `XDATA[0x2522]` (selects move opcode
      `0xD2` over `0xD1`) and capture a `0xD2` move on the wire.
- [x] ~~Probe standard PMBus codes — is `0x01` an alternate enable?~~ — answered
      from firmware: **not PMBus.** `0x01` (write) is an *arm-motion* command
      (`GPIOR0|=0x80`); `0x98/0x99` are block reads of internal RAM buffers; `0x03`
      is unhandled. See the full read/write opcode maps above.
- [ ] Map `0xA4` counts to physical travel (counts per revolution / per mm).

---

## Captures

In `../csz1-control-board/captures/`:

- `up_down.sal` — full open/close via button (run-to-limit, `0xD1 = ±1`).
- `percent_based_moves.sal` — two partial (percent) moves then close.
- `100_25_75_0.sal` — open → 25% → 75% → 0% (closed); confirms linear percent mapping.

A logic-analyzer MCP server is configured for loading/analyzing these `.sal` files.

## Hardware reference

- **MCU:** SD3502 (Z-Wave 500-series, 8051). Firmware in internal flash, read via
  the Sigma/SiLabs 500-series programming FSM (not SWD; INS11681). **Not**
  lock-protected on this unit — readback is open and the 128 KB image was dumped;
  see [the CSZ1 doc](../csz1-control-board/README.md).
- **Module:** ZM5202 (12.5×13.6 mm), pins 7/8/9 = SPI1 MISO/SCK/MOSI to the 25PE20 flash.
- **External flash:** 25PE20VP, 256 KB SPI — OTA image staging / NVM. Dumped and
  analyzed separately; see [the CSZ1 doc](../csz1-control-board/README.md).
