# VCZ1 — Virtual Cord Control (2-button Z-Wave remote)

The **VCZ1** is the handheld **two-button Z-Wave remote** for the blind system.
It pairs to the [CSZ1 controller](../csz1-control-board/README.md) over **Z-Wave
RF** (the VCZ1 has no wired link to the motor board — that is the CSZ1's job; see
the [protocol doc](../docs/PROTOCOL.md)). This document covers the remote's
purpose, silicon, external memory, and how its NVM was dumped.

Part of the [Springs Window Fashions Z-Wave blind project](../README.md).

> Status: chip identity, pinout, dump procedure, and the manufacturer/serial
> records are **confirmed** (cross-checked against the Z-Wave Alliance cert). The
> finer NVM layout (identity block, the `field2` value, TLV record framing) is
> partially inferred — see *Open items*.

## Overview

| | VCZ1 |
|:--|:--|
| Z-Wave product | Virtual Cord Control (2-button remote) |
| Z-Wave module | **ZM5101** |
| SoC | Sigma/SiLabs ZW0500-series (500-series, 8051 core) |
| External memory | **Catalyst/ON CAV25256** SPI EEPROM, 256 Kbit / **32 KiB** |
| Manufacturer ID | `0x026E` |
| Product Type ID | `0x5643` ("VC") |
| Product ID | `0x5A31` ("Z1") |
| Z-Wave Alliance cert | [ZC10-16055082][zwa-vcz1] |
| FCC ID | DWNVCZ |
| Z-Wave version | 6.61.00 |
| Firmware | 187.65 |

## Photos

No dedicated photos of the VCZ1 PCB yet. For now it appears as the **rightmost
board** in the project's group shots ([component side](../top.jpg),
[solder side](../bottom.jpg)) — the green roughly-square board. Drop close-ups
into [`images/`](images/) and reference them here when available, e.g.:

```markdown
![VCZ1 remote, front](images/vcz1-front.jpg)
![VCZ1 board, CAV25256 EEPROM area](images/vcz1-board-eeprom.jpg)
```

## Hardware

### CAV25256 — SPI EEPROM

The remote's non-volatile config lives in a **CAV25256 SPI EEPROM** (TSSOP-8, top
marking **`S56E`**, second line a date/lot code `AYMXXX`). This is an **EEPROM,
not flash** — that distinction drives the tooling choice below.

- **No JEDEC RDID command.** flashrom cannot identify it (a stable `0xFF` on
  probe is *expected*, not a wiring fault).
- Command set is the simple 25-series EEPROM set: `WREN 0x06`, `RDSR 0x05`,
  `READ 0x03`, `WRITE 0x02`, with 16-bit addressing.
- Datasheet: [CAV25256][ds-cav25256].

### Pinout → FT232H wiring

Standard 8-pin 25-series SPI pinout. WP#, HOLD#, and VCC all tie to **3.3 V** (the
FT232H **3V** pin — **never 5V**).

| SPI pin # | CAV25256 | Function | → FT232H |
|:---------:|:---------|:---------|:--------:|
| 1 | CS#   | Chip select | D3 |
| 2 | SO    | Serial out (MISO) | D2 |
| 3 | WP#   | Write protect | 3V |
| 4 | VSS   | Ground | GND |
| 5 | SI    | Serial in (MOSI) | D1 |
| 6 | SCK   | Serial clock | D0 |
| 7 | HOLD# | Hold | 3V |
| 8 | VCC   | Power | 3V |

## Firmware / NVM

> The VCZ1's Z-Wave application firmware lives in the ZW0500 SoC's **internal
> flash**, not in the external EEPROM. Only the external EEPROM has been dumped on
> this unit; the internal flash was dumped on the *CSZ1* (same SoC family) — see
> the [CSZ1 doc](../csz1-control-board/README.md) for that procedure if you want
> to attempt it on the remote.

### Reading the CAV25256 (pyftdi)

flashrom is a *flash* tool and can't talk to a plain SPI EEPROM, so this chip was
**desoldered onto a breakout** (standalone — no SoC bus contention) and read by
issuing the EEPROM `READ` command directly over an **FT232H in MPSSE SPI mode**
(D0=SCK, D1=MOSI, D2=MISO, D3=CS0) via `pyftdi`:

```bash
# run from the repo root
python3 -m venv .venv && .venv/bin/pip install pyftdi
.venv/bin/python vcz1-remote/tools/eeprom_probe.py   # RDSR liveness + first 16 bytes
.venv/bin/python vcz1-remote/tools/eeprom_dump.py vcz1-remote/cav25256.bin
```

`eeprom_dump.py` opens `ftdi://ftdi:232h/1`, SPI mode 0, CS0, and does
`exchange([0x03, 0x00, 0x00], 32768)` — READ from address 0, 32 KiB. A healthy
status register reads `0x00` (not floating `0xFF`).

> **Field guide:** a stable `0xFF` on probe is **normal** for this EEPROM (no RDID
> command) — use pyftdi, not flashrom. A floating status register that won't
> settle to `0x00`, or the whole FT232H vanishing from USB (`0403:6014` gone), is
> a wiring/power fault — re-seat and check for shorts. Use the FT232H **3V** pin
> only; the 5V pin would over-volt the part.

### What's in the dump

`cav25256.bin` (32 KiB) is almost entirely erased (`0xFF`/`0x00`); the real config
sits in one small block at **`0x2980–0x29C8`**. It shares the **same record
structure** as the CSZ1's config block, just relocated (see the ImHex pattern for
exact offsets and field colors):

- **Protocol header / NVM descriptor** — region the ZW0500 nvm module manages;
  layout not decoded. Scattered `0xFE` bytes are "unwritten" markers.
- **Device identity** — ~8 bytes of per-unit random data; first 4 most likely the
  **Z-Wave Home ID**, trailing bytes look like key/seed material (unconfirmed).
- **Serial number** — null-terminated ASCII `"5126726A006"`.
- **Manufacturer Specific record** (Command Class 0x72), big-endian:
  `manufacturer_id` (`0x026E`), a 16-bit `field2` (`0x5741` "WA" — role unknown),
  `product_type_id` (`0x5643`), `product_id` (`0x5A31`).

The config block appears to use **`0x0B`-length-prefixed (TLV) records** — a
`0x0B` (=11) byte followed by exactly 11 bytes, then the next `0x0B`. The
manufacturer record lives inside one such record; the full TLV grammar isn't
confirmed from the available dumps.

#### Using the ImHex pattern

Load `vcz1-remote/nvm.hexpat`. It `#include`s shared types from
`shared/includes/swf_zwave_common.pat` — add the repo's `shared/` folder under
**ImHex → Extras → Settings → Folders** so the `#include` resolves. See the
[top-level README](../README.md#imhex-patterns-nvm-dumps).

## Files

| File | What |
|:--|:--|
| `cav25256.bin` | VCZ1 remote EEPROM dump (32 KiB) |
| `nvm.hexpat` | ImHex pattern for the dump |
| `tools/eeprom_probe.py` | pyftdi RDSR liveness check + first-16-bytes read |
| `tools/eeprom_dump.py` | pyftdi full 32 KiB EEPROM dump |
| `images/` | board / device photos |

## Open items

- [ ] Identify `field2` (`0x5741` on VCZ1, `0x6783` on CSZ1) — fixed product
      attribute or per-unit? A second dump of either model would settle it.
- [ ] Confirm the device-identity block boundary (it doesn't align cleanly with
      the CSZ1 layout) and whether bytes 0–3 are the Z-Wave Home ID.
- [ ] Confirm the `0x0B`-prefixed TLV record framing across the whole config
      block.
- [ ] Determine whether network security keys live in the external EEPROM or only
      in the SoC.
- [ ] (Optional) Dump the ZM5101 SoC's internal flash via the 500-series
      programming FSM, as was done on the CSZ1.

## References

- VCZ1 — [Virtual Cord Remote Control Z-Wave][zwa-vcz1] (cert ZC10-16055082)
- [CAV25256][ds-cav25256] — SPI EEPROM datasheet

[zwa-vcz1]: https://products.z-wavealliance.org/z-wave-product/virtual-cord-remote-control-z-wave/
[ds-cav25256]: https://www.onsemi.com/download/data-sheet/pdf/cav25256-d.pdf
