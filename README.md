# Z-Wave Motorized Blind — Reverse Engineering

Reverse-engineering notes, memory dumps, and analysis tooling for a Springs
Window Fashions (Somfy) Z-Wave motorized blind system. Two devices:

- **CSZ1** — *Cellular Shade Radio*, the control board inside the blind (Z-Wave
  brain + motor driver, on a ZM5202 module).
- **VCZ1** — *Virtual Cord Control*, the two-button handheld remote (ZM5101).

## Documentation

- **[docs/HARDWARE.md](docs/HARDWARE.md)** — silicon, memory chips, dump
  procedure (FT232H + flashrom/pyftdi), and what's in the NVM dumps.
- **[docs/PROTOCOL.md](docs/PROTOCOL.md)** — the control-board ↔ motor-board
  protocol (bit-banged I²C / SMBus, command map, move/position semantics),
  derived from logic-analyzer captures.

## Layout

```
csz1-control-board/     CSZ1 (in-blind controller)
  m25pe20.bin             256 KiB SPI flash dump
  nvm.hexpat              ImHex pattern for the dump
  captures/               logic-analyzer .sal/.csv (motor protocol)
vcz1-remote/            VCZ1 (2-button remote)
  cav25256.bin            32 KiB SPI EEPROM dump
  nvm.hexpat              ImHex pattern for the dump
  tools/                  pyftdi scripts used to read the EEPROM
shared/
  includes/               shared ImHex types (#include'd by both patterns)
docs/                   HARDWARE.md, PROTOCOL.md
```

## Using the ImHex patterns

Add this repo's **`shared/`** folder under **ImHex → Extras → Settings →
Folders** (ImHex resolves `#include` from `shared/includes/`), then open a dump
and load the matching `nvm.hexpat`.

## Reading the EEPROM (pyftdi)

```bash
python3 -m venv .venv && .venv/bin/pip install pyftdi
.venv/bin/python vcz1-remote/tools/eeprom_dump.py vcz1-remote/cav25256.bin
```

> Not affiliated with Springs Window Fashions or Somfy. For interoperability and
> research on hardware the author owns.
