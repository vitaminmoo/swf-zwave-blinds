# Z-Wave Blind System — Hardware & Memory

Reverse-engineering notes on the **silicon and non-volatile memory** of a Z-Wave
motorized blind system. Companion to [`PROTOCOL.md`](PROTOCOL.md), which covers
the control-board ↔ motor-board communication. This document covers the Z-Wave
modules, the external memory chips, how they were dumped, and what the dumps
contain.

The system is two separate Z-Wave devices from the same vendor:

- **CSZ1** — *Cellular Shade Radio*. The **control board inside the blind**
  (the "brain" described in `PROTOCOL.md`); it commands the motor board.
- **VCZ1** — *Virtual Cord Control*. A **two-button handheld remote**.

Both are made by **Springs Window Fashions** (a Somfy partner; Z-Wave
Manufacturer ID **`0x026E`**), built on Z-Wave 500-series modules.

Inside the blind, the CSZ1 talks to a **third** board — an **ATmega168P** motor
controller (*SWF Killer Bee Motor Control Rev 2.3*). Its firmware was dumped over
ISP and analysed separately; see [`MOTOR_BOARD.md`](MOTOR_BOARD.md).

> Status: chip identities, pinouts, dump procedure, and the manufacturer/serial
> records are **confirmed** (cross-checked against Z-Wave Alliance certs). The
> finer NVM layout (identity block, the `field2` value, the TLV record framing)
> is partially inferred — see *Open items*.

---

## Devices at a glance

| | CSZ1 (control board) | VCZ1 (remote) |
|:--|:--|:--|
| Z-Wave product | Cellular Shade Radio | Virtual Cord Control |
| Role | In-blind controller / motor driver | 2-button handheld remote |
| Z-Wave module | [**ZM5202**][ds-zm5202] (12.5×13.6 mm) | **ZM5101** |
| SoC | Sigma/SiLabs **SD3502** (ZW0500, 500-series, 8051) | ZW0500-series |
| External memory | **Micron/ST M25PE20** (SPI flash) | **Catalyst/ON CAV25256** (SPI EEPROM) |
| Memory size | 2 Mbit / **256 KiB** | 256 Kbit / **32 KiB** |
| Manufacturer ID | `0x026E` | `0x026E` |
| Product Type ID | `0x4353` ("CS") | `0x5643` ("VC") |
| Product ID | `0x5A31` ("Z1") | `0x5A31` ("Z1") |
| Z-Wave Alliance cert | [ZC10-16055081][zwa-csz1] | [ZC10-16055082][zwa-vcz1] |
| FCC ID | DWNCSZ | DWNVCZ |
| Z-Wave version | 6.61.00 | 6.61.00 |
| Firmware | 187.65:1.09 | 187.65 |
| Dump file | `csz1_blind-control-board_m25pe20.bin` | `vcz1_2button-remote_cav25256.bin` |
| ImHex pattern | `csz1_blind-control-board_nvm.hexpat` | `vcz1_2button-remote_nvm.hexpat` |

Neat detail: the vendor encodes the **SKU as ASCII inside the 16-bit Product
Type / Product ID fields**, so each device "names itself" in a hex dump —
`0x4353 0x5A31` = `"CSZ1"`, `0x5643 0x5A31` = `"VCZ1"` (VC = *Virtual Cord*).

---

## Memory chips & pinouts

Both are 8-pin SPI parts with the standard 25-series pinout. **The M25PE20 is
flash; the CAV25256 is an EEPROM** — that distinction matters for tooling (see
below).

### M25PE20 (CSZ1 control board) — SPI flash

JEDEC RDID `20 80 12` (Micron/ST, "PE" page-erase family, 2 Mbit). On the module
this is the OTA/NVM flash on the ZM5202's SPI1 bus (module pins 7/8/9 =
MISO/SCK/MOSI). Datasheet: [AT25PE20][ds-pe20] (the equivalent
Renesas/Adesto-marked PE20 part; pin- and command-compatible).

### CAV25256 (VCZ1 remote) — SPI EEPROM

TSSOP-8, top marking **`S56E`**, second line a date/lot code (`AYMXXX`).
**No JEDEC RDID command** — flashrom cannot identify it (a stable `0xFF` on probe
is *expected*, not a wiring fault). Command set is the simple 25-series EEPROM
set: `WREN 0x06`, `RDSR 0x05`, `READ 0x03`, `WRITE 0x02`, 16-bit addressing.
Datasheet: [CAV25256][ds-cav25256].

### Pinout → FT232H wiring (both parts)

| SPI pin # | M25PE20 | CAV25256 | Function | → FT232H |
|:---------:|:--------|:---------|:---------|:--------:|
| 1 | CS#   | CS#   | Chip select | D3 |
| 2 | SO    | SO    | Serial out (MISO) | D2 |
| 3 | WP#   | WP#   | Write protect | 3V |
| 4 | VSS   | VSS   | Ground | GND |
| 5 | SI    | SI    | Serial in (MOSI) | D1 |
| 6 | SCK   | SCK   | Serial clock | D0 |
| 7 | RESET#| HOLD# | Reset / Hold | 3V |
| 8 | VCC   | VCC   | Power | 3V |

WP# (3), the pin-7 control, and VCC all tie to **3.3 V** (the FT232H **3V** pin —
**never 5V**). Pin 7 differs by part (RESET# vs HOLD#) but is tied high either way.

---

## Reading the memory

Programmer: **FT232H breakout in MPSSE SPI mode** (D0=SCK, D1=MOSI, D2=MISO,
D3=CS0), the same adapter for both chips.

### M25PE20 flash — flashrom

```bash
# Identify (force the chip type; flashrom lists it as "unknown" otherwise)
flashrom -p ft2232_spi:type=232H,divisor=10 -c M25PE20

# Dump (read twice, compare hashes)
flashrom -p ft2232_spi:type=232H,divisor=10 -c M25PE20 -r dump1.bin
flashrom -p ft2232_spi:type=232H,divisor=10 -c M25PE20 -r dump2.bin
sha256sum dump1.bin dump2.bin
```

**Critical gotcha — in-circuit bus contention.** Read in-circuit on the control
board, the ZW0500 SoC powers up (back-fed through the flash's VCC pin) and drives
the shared SPI bus, fighting the FT232H. Symptom: garbage / unstable RDID, or
`0xFF`. **Fix: hold the ZM5202 `RESET_N` pin (module pin 2) to GND** for the whole
read — this tri-states the SoC's SPI pins and frees the bus. The hold must be
*solid and continuous* (a tapped reset just makes the SoC reboot). A clean read
shows a **stable** ID across repeated probes. `divisor=10` (~6 MHz) keeps the
slow/long breadboard wiring reliable.

### CAV25256 EEPROM — pyftdi

flashrom is a *flash* tool and can't talk to a plain SPI EEPROM, so this chip was
**desoldered onto a breakout** (standalone — no SoC contention) and read by
issuing the EEPROM `READ` command directly over the FT232H via `pyftdi`:

```bash
# run from the repo root
python3 -m venv .venv && .venv/bin/pip install pyftdi
.venv/bin/python vcz1-remote/tools/eeprom_probe.py   # RDSR liveness + first 16 bytes
.venv/bin/python vcz1-remote/tools/eeprom_dump.py vcz1-remote/cav25256.bin
```

`eeprom_dump.py` opens `ftdi://ftdi:232h/1`, SPI mode 0, CS0, and does
`exchange([0x03, 0x00, 0x00], 32768)` — READ from address 0, 32 KiB. A healthy
status register reads `0x00` (not floating `0xFF`).

---

## What's in the dumps

Both images are almost entirely erased (`0xFF`/`0x00`); real data sits in one
small config block — `0x1200–0x1266` on the CSZ1, `0x2980–0x29C8` on the VCZ1.
The two blocks share the **same record structure**, just relocated.

Structure (see the ImHex patterns for exact offsets and field colors):

- **Protocol header / NVM descriptor** — region the ZW0500 nvm module manages;
  layout not decoded. Scattered `0xFE` bytes are "unwritten" markers.
- **Device identity** — ~8 bytes of per-unit random data; first 4 most likely the
  **Z-Wave Home ID**, trailing bytes look like key/seed material (unconfirmed).
- **Serial number** — null-terminated ASCII (CSZ1 `"5126732A003"`,
  VCZ1 `"5126726A006"`).
- **Manufacturer Specific record** (Command Class 0x72), big-endian:
  `manufacturer_id` (`0x026E`), a 16-bit `field2` (CSZ1 `0x6783`, VCZ1 `0x5741`
  "WA" — role unknown), `product_type_id`, `product_id`.

The config block appears to use **`0x0B`-length-prefixed (TLV) records** — a `0x0B`
(=11) byte followed by exactly 11 bytes, then the next `0x0B`. The manufacturer
record lives inside one such record. The full TLV grammar isn't confirmed from the
available dumps.

**Not in these dumps:** the Z-Wave protocol version, application firmware, and
device icons live in the **SD3502 internal flash**, not the external memory. That
flash is reached through Sigma's 500-series programming interface (not SWD) — and
on this unit it turned out **not** to be lock-protected, so it *was* dumped. See
*Reading the internal flash* below.

---

## Reading the internal flash (SD3502 programming FSM)

The SD3502's on-chip memory is read through the **500-series programming
interface** (SPI/UART/USB; *not* SWD), documented in Silicon Labs
[INS11681][ins11681]. Entry: hold the module's `RESET_N` (pin 2) low ≥5.1 ms,
clock the *Enable Interface* string `AC 53 AA 55`, then issue 4-byte commands.
The interface is identical on SPI1 and UART0 — we used **SPI1** because it's
already broken out to the M25PE20 and avoids the off-board RC filtering on the
UART0 lines.

> **Access aside:** the unit's USB-micro "power" port is **not USB** — it's 12 V
> on VBUS with the SoC's **UART0** on the data pins (the same pins that become the
> motor-board I²C). It's almost certainly the factory program/update port; the
> `0x42 0x01 0xBD` boot announce (see `PROTOCOL.md`) is a bootloader hello with a
> ~3 s listen window. That path is write/update-only, so the **dump uses the
> SPI1 FSM instead.**

**Wiring** — reuse the M25PE20 chip-clip harness, add one soldered wire:

| Signal | Module pin | Clip pin | FT232H |
|:--|:--:|:--:|:--:|
| SCK | 8 | 6 | D0 |
| MOSI | 9 | 5 | D1 |
| MISO | 7 | 2 | D2 |
| GND | — | 4 | GND |
| VCC (back-power, 3.3 V) | — | 8 | 3V3 |
| `RESET_N` | 2 | — *(solder)* | D4 |

In programming mode the SoC pulls the flash's CS# high (deselected), so the
shared bus is clean. The FT232H **I²C switch must be OFF** (it shorts D1/D2).

**Result — readback is OPEN on this unit.** Signature `7F 7F 7F 7F 1F 04 01`
(ZW0500, rev 01); lock bytes `FF FF FF FF FF FF FF FF FF` → **RBAP bit 0 = 1**
(no read-back protection) and EP0–EP7 = `FF` (no erase protection). Sector 0
begins with a valid 8051 vector table (`02 03 37` = `LJMP 0x0337` at reset).

Dumped with [`tools/sd3502_fsm_probe.py`](../csz1-control-board/tools/sd3502_fsm_probe.py)
`--dump`: all 64 × 2 KB sectors plus the NVR (`0x09–0xFF`). The tool is strictly
read-only — it never issues erase/write/lock commands. The MTP data area
(register-addressed) and SRAM (volatile) are not FSM-readable and are not dumped.

**Integrity:** read twice with identical SHA-256, and the first 16 bytes match
the expected 8051 vector table. The on-chip CRC-32 slot (top 4 bytes,
`0x1FFFC–0x1FFFF`) is **unprogrammed** (`FF FF FF FF`) — this application doesn't
use that feature (OTA validates via the external-NVM CRC instead), so a CRC
"mismatch" from the tool is expected, not a read error.

**`sd3502_internal.bin`** (128 KiB, sha256 `9329071c…d2d738f`) is ~55 % content,
~45 % `0xFF` erased. Notable strings: a serial/ID `"5120199"` (`0x181d`), the
Z-Wave Association Group-1 name `"Lifeline"` with its association table
(`0x2268`), and an app version string **`"Z-Wave 4.33"`** (`0x24e5`) — the
firmware's self-reported version, separate from the certified protocol version
`6.61.00`.

## Files

| File | What |
|:--|:--|
| `csz1-control-board/sd3502_internal.bin` | **CSZ1 SD3502 internal flash dump (128 KiB)** |
| `csz1-control-board/sd3502_nvr.bin` | CSZ1 SD3502 NVR dump (247 B, base addr `0x09`) |
| `csz1-control-board/tools/sd3502_fsm_probe.py` | 500-series programming-FSM reader/dumper (pyftdi) |
| `csz1-control-board/m25pe20.bin` | CSZ1 control-board flash dump (256 KiB) |
| `csz1-control-board/nvm.hexpat` | ImHex pattern for the CSZ1 dump |
| `csz1-control-board/captures/` | Logic-analyzer captures (see `PROTOCOL.md`) |
| `vcz1-remote/cav25256.bin` | VCZ1 remote EEPROM dump (32 KiB) |
| `vcz1-remote/nvm.hexpat` | ImHex pattern for the VCZ1 dump |
| `vcz1-remote/tools/eeprom_probe.py`, `eeprom_dump.py` | pyftdi scripts for the CAV25256 |
| `shared/includes/swf_zwave_common.pat` | Shared ImHex types for both patterns |

> ImHex `#include` resolves from an `includes/` subfolder on a configured pattern
> path. Add the repo's **`shared/`** folder under **Extras → Settings → Folders**
> (ImHex then looks in `shared/includes/`) so the patterns find
> `swf_zwave_common.pat`.

---

## Field guide / gotchas

- **Stable `0xFF` on probe** = MISO floating, chip not answering. On *flash*, that
  means a wiring/solder fault. On the *CAV25256 EEPROM*, it's **normal** (no RDID
  command) — use pyftdi, not flashrom.
- **Garbage / unstable RDID** = bus contention from an active SoC. Hold the
  module's `RESET_N` low (and watch for back-powering through the chip's VCC).
- **The whole adapter vanishing from USB** (no `0403:6014`) = loose USB or a
  wiring short browning out the FT232H. Re-seat and check for shorts before
  re-probing.
- **3.3 V only.** Use the FT232H **3V** pin for VCC/WP#/HOLD#/RESET#; the 5V pin
  would over-volt these parts.
- **Verify every dump** by reading twice and comparing SHA-256.

---

## Open items

- [ ] Identify `field2` (`0x6783` on CSZ1, `0x5741` on VCZ1) — fixed product
      attribute or per-unit? A second dump of either model would settle it.
- [ ] Confirm the device-identity block boundary (esp. on the VCZ1, where it
      doesn't align cleanly with the CSZ1 layout) and whether bytes 0–3 are the
      Z-Wave Home ID.
- [ ] Confirm the `0x0B`-prefixed TLV record framing across the whole config block.
- [ ] Determine whether network security keys are stored in the external memory or
      only in the SoC.
- [x] ~~(Out of scope / likely locked) SD3502 internal firmware ROM via the Sigma
      proprietary programming interface.~~ **Done** — readback was *not* locked;
      128 KB flash + NVR dumped over the SPI1 programming FSM (see *Reading the
      internal flash*); version string `"Z-Wave 4.33"` and serial `"5120199"`
      recovered. Follow-up: disassemble `sd3502_internal.bin` (8051) — start with
      the `0x1800` LJMP jump table the reset/interrupt vectors point into.

---

## References

**Z-Wave Alliance product pages**
- CSZ1 — [Cellular Shade Radio Z-Wave][zwa-csz1] (cert ZC10-16055081)
- VCZ1 — [Virtual Cord Remote Control Z-Wave][zwa-vcz1] (cert ZC10-16055082)

**Component datasheets**
- [AT25PE20][ds-pe20] — SPI flash on the CSZ1 control board (PE20 family;
  equivalent to the Micron M25PE20 we read)
- [CAV25256][ds-cav25256] — SPI EEPROM in the VCZ1 remote
- [ZM5202][ds-zm5202] — Z-Wave 500-series module (CSZ1)
- [INS11681][ins11681] — 500-series chip programming mode (FSM command set,
  lock bits, RBAP, on-chip CRC-32) — the procedure used to dump the SD3502

**Product documentation**
- [SWF Cellular/Pleated Shade Installation Instructions][install] — pairing,
  limit setting, and remote operation procedures

[zwa-csz1]: https://products.z-wavealliance.org/z-wave-product/cellular-shade-radio-z-wave/
[zwa-vcz1]: https://products.z-wavealliance.org/z-wave-product/virtual-cord-remote-control-z-wave/
[ds-pe20]: https://www.mouser.com/datasheet/2/698/REN_DS_AT25PE20_139D_022022_unsecure_DST_20220220_-3076023.pdf
[ds-cav25256]: https://www.onsemi.com/download/data-sheet/pdf/cav25256-d.pdf
[ds-zm5202]: https://www.silabs.com/documents/public/data-sheets/DSH12435-15.pdf
[ins11681]: https://www.silabs.com/documents/public/user-guides/INS11681-Instruction-500-Series-Z-Wave-Chip-Programming-Mode.pdf
[install]: https://media.blinds.com/pdfs/SWF_CellPleated_InstallationInstructions.pdf
