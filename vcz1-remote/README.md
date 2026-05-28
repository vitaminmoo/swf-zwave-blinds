# VCZ1 — Virtual Cord Control (2-button Z-Wave remote)

The **VCZ1** is the handheld **two-button Z-Wave remote** for the blind system.
It pairs to the [CSZ1 controller](../csz1-control-board/README.md) over **Z-Wave
RF** (the VCZ1 has no wired link to the motor board — that is the CSZ1's job; see
the [protocol doc](../docs/PROTOCOL.md)). This document covers the remote's
purpose, silicon, external memory, and how its NVM was dumped.

Part of the [Springs Window Fashions Z-Wave blind project](../README.md).

> Status: chip identity, pinout, dump procedure, and the manufacturer/serial
> records are **confirmed** (cross-checked against the Z-Wave Alliance cert). The
> NVM config block is decoded by analogy to the CSZ1 firmware (firmware-default
> bytes + per-unit data, not a TLV); the only inference left is where the Home ID
> begins inside the identity blob — see *Open items*.

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
sits in one small block at **`0x2980–0x29C8`**. It is the **same layout** as the
CSZ1's config block, just relocated near the end of the chip. The VCZ1 firmware
wasn't dumped, but the manufacturer blob and its neighbours are byte-for-byte the
CSZ1 structure (only the product constants differ), so the same scheme applies
(structure decoded from the [CSZ1 firmware](../csz1-control-board/README.md)):

- **Firmware defaults** — the manufacturer-specific blob at `0x29B6` is a
  compile-time constant: `manufacturer_id` (`0x026E`), `field2` (`0x5741` "WA"),
  `product_type_id` (`0x5643`), `product_id` (`0x5A31`). `field2` is a **fixed
  per-product value**, not per-unit (meaning still unknown).
- **Per-unit factory / inclusion data** — the null-terminated serial
  `"5126726A006"` (`0x299C`, preceded by a `0x42` marker), and a `0x42`-bracketed
  **identity blob** (`0x2989…0x2992`): 8 bytes whose middle 4 (`e7 2e 93 2e`) look
  like the **Z-Wave Home ID**.

> The earlier "`0x0B`-length-prefixed TLV records" guess is **wrong** — see the
> [CSZ1 doc](../csz1-control-board/README.md): the block is firmware-initialized
> defaults + per-unit data, not an in-NVM TLV.

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

- [x] ~~Identify `field2` — fixed product attribute or per-unit?~~ **Fixed
      product attribute** — a compile-time firmware constant (resolved on the CSZ1,
      same scheme here); `0x5741` for the VCZ1. Semantics still unknown.
- [x] ~~Confirm the `0x0B`-prefixed TLV record framing.~~ **Disproven** — the block
      is firmware-initialized defaults + per-unit data, not an in-NVM TLV (see the
      [CSZ1 doc](../csz1-control-board/README.md)).
- [x] ~~Determine whether network security keys live in the external EEPROM.~~
      **Not present** — sliding-window scan finds no 16-byte key-shaped blob in any
      dump; a key would live in SoC MTP (not dumped) or was never bootstrapped.
- [ ] Confirm where the Home ID begins inside the `0x42`-bracketed identity blob
      (typed as the middle 4 bytes). A second VCZ1 dump would settle it.
- [ ] (Optional) Dump the ZM5101 SoC's internal flash via the 500-series
      programming FSM, as was done on the CSZ1 — would confirm the VCZ1's own
      firmware-default table and `field2`.

## References

- VCZ1 — [Virtual Cord Remote Control Z-Wave][zwa-vcz1] (cert ZC10-16055082)
- [CAV25256][ds-cav25256] — SPI EEPROM datasheet

[zwa-vcz1]: https://products.z-wavealliance.org/z-wave-product/virtual-cord-remote-control-z-wave/
[ds-cav25256]: https://www.onsemi.com/download/data-sheet/pdf/cav25256-d.pdf
