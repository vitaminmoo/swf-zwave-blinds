#!/usr/bin/env python3
"""
SD3502 (ZW0500 / ZM5202) internal-memory reader over the 500-series
programming FSM (SPI1), per Silicon Labs INS11681.

Default mode: a *read-only* verdict on whether the internal code flash can be
dumped (sync -> signature -> RBAP lock bit -> first bytes of sector 0).

--dump mode: read every readable non-volatile memory:
    - 128 KB code flash  (Read Flash 0x10 + Continue Read 0xA0), twice, and
      compare SHA-256, then verify against the chip's own on-chip CRC-32.
    - NVR  0x09..0xFF     (Read NVR 0xF2)  -> lock/calibration/identity area.
Writes  sd3502_internal.bin  and  sd3502_nvr.bin  next to the dump folder.

It issues ONLY non-destructive commands. It NEVER sends Erase Chip (0x0A),
Erase Sector (0x0B), Write Flash (0x20), Write SRAM (0x04), Continue Write
(0x80), Set Lock Bits (0xF0) or Set NVR (0xFE). With no recovery image, those
would risk an unrecoverable brick.

Not dumped:
    - MTP / 255-byte data area: addressed through registers, no FSM read cmd.
    - SRAM: volatile and uninitialised at programming-mode entry (not firmware).

Wiring (in-circuit, SOIC clip on the M25PE20, shared SPI1 bus):
    clip 6 (SCK)  -> FT232H D0   clip 5 (SI)  -> D1 MOSI   clip 2 (SO) -> D2 MISO
    clip 4 (VSS)  -> GND         clip 8 (VCC) -> 3V3 (back-power, 3.3 V ONLY)
    module pin 2 (RESET_N) -> FT232H D4 (ADBUS4)   [soldered]
FT232H "I2C" switch (if present) MUST be OFF (it shorts D1/D2 for I2C SDA).
"""

import argparse
import hashlib
import os
import sys
import time

from pyftdi.spi import SpiController

URL = "ftdi://ftdi:232h/1"
RST = 1 << 4  # RESET_N on ADBUS4 / D4

ENABLE = bytes([0xAC, 0x53, 0xAA, 0x55])
SIG_EXPECT = bytes([0x7F, 0x7F, 0x7F, 0x7F, 0x1F, 0x04])  # bytes 0..5; [6]=rev

SECTOR_SIZE = 2048
NUM_SECTORS = 64
FLASH_SIZE = SECTOR_SIZE * NUM_SECTORS  # 0x20000
CRC_REGION = FLASH_SIZE - 4             # CRC-32 itself lives in the top 4 bytes

# Known-good first 16 bytes of sector 0 (8051 vector table) from the probe run;
# a self-check that the batched Continue Read stays byte-aligned.
KNOWN_VEC = bytes.fromhex("02 03 37 02 18 03 41 00 c4 00 22 02 18 0b 22 22")

OUT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rd(port, b0, b1, b2=0xFF, b3=0xFF):
    """One 4-byte FSM command, full-duplex. SPI echoes one byte late, so a
    read command's payload lands in response[3]."""
    return port.exchange(bytes([b0, b1, b2, b3]), duplex=True)


def zw_crc32(data):
    """INS11681 on-chip CRC-32: poly 0x04C11DB7, init 0xFFFFFFFF, MSB-first,
    no reflection, no final XOR (== CRC-32/MPEG-2)."""
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 \
                else (crc << 1) & 0xFFFFFFFF
    return crc


CHUNK_GROUPS = 64  # Continue Reads per USB exchange (small -> no duplex stall)


def dump_flash(port):
    """Read all 64 sectors. Per sector: Read Flash sets the address and yields
    the first byte; Continue Reads (batched in small chunks to avoid a full-
    duplex USB stall) fill the rest. The read address continues across
    exchanges, so chunking is safe."""
    out = bytearray()
    for sec in range(NUM_SECTORS):
        sector = bytearray([rd(port, 0x10, sec)[3]])     # first byte of sector
        while len(sector) < SECTOR_SIZE:
            ng = min(CHUNK_GROUPS, (SECTOR_SIZE - len(sector) + 2) // 3)
            resp = port.exchange(bytes([0xA0, 0x00, 0x00, 0x00]) * ng,
                                 duplex=True)
            for i in range(ng):
                sector += resp[i * 4 + 1:i * 4 + 4]      # Data0,Data1,Data2
        out += sector[:SECTOR_SIZE]
        print(f"\r    flash sector {sec + 1}/{NUM_SECTORS}", end="", flush=True)
    print()
    return bytes(out)


def dump_nvr(port):
    """NVR readable range is 0x09..0xFF (Table 3). Returns those 247 bytes."""
    return bytes(rd(port, 0xF2, 0x00, addr, 0xFF)[3] for addr in range(0x09, 0x100))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dump", action="store_true",
                    help="full dump of flash + NVR to .bin files")
    ap.add_argument("--freq", type=float, default=100e3,
                    help="SPI clock Hz (default 100k; slow clock satisfies the "
                         "inter-byte waits of Table 2 implicitly; keep <=700k)")
    ap.add_argument("--release-reset", action="store_true",
                    help="drive RESET_N high at the end so the board reboots")
    args = ap.parse_args()

    spi = SpiController(cs_count=1)
    spi.configure(URL)
    port = spi.get_port(cs=0, freq=args.freq, mode=0)  # SPI mode 0, MSB first
    gpio = spi.get_gpio()
    gpio.set_direction(RST, RST)

    try:
        print("[*] Asserting RESET_N (D4) low ...")
        gpio.write(0)
        time.sleep(0.05)  # >> 5.1 ms

        synced = False
        for attempt in range(1, 32):
            r = rd(port, *ENABLE)
            if r[2] == 0x53 and r[3] == 0xAA:
                synced = True
                print(f"[+] Programming-mode sync OK (attempt {attempt})")
                break
        if not synced:
            print("[-] Never synced. Last response:", r.hex(" "))
            return 2

        sig = bytes(rd(port, 0x30, n)[3] for n in range(7))
        print(f"[*] Signature: {sig.hex(' ')}")
        if sig[:6] != SIG_EXPECT:
            print("[-] Signature mismatch; not trusting reads. Stopping.")
            return 3
        print(f"[+] SD3502/ZW0500 confirmed (chip rev 0x{sig[6]:02x})")

        lock = bytes(rd(port, 0xF1, n)[3] for n in range(9))
        rbap = lock[8]
        protected = (rbap & 0x01) == 0
        print(f"[*] Lock bytes (EP0..EP7,RBAP): {lock.hex(' ')}")
        print(f"[*] RBAP = 0x{rbap:02x}  (Readback-Protection = "
              f"{'0 PROTECTED' if protected else '1 open'})")

        if protected:
            print("\n=== LOCKED: read-back protection set; flash reads as 0x00. ===")
            return 0

        if not args.dump:
            data = bytearray([rd(port, 0x10, 0x00)[3]])
            for _ in range(5):
                data += rd(port, 0xA0, 0x00, 0x00, 0x00)[1:4]
            print(f"[*] Sector 0, first {len(data)} bytes: {bytes(data).hex(' ')}")
            print("\n=== OPEN: flash is readable. Re-run with --dump. ===")
            return 0

        # ---- full dump -----------------------------------------------------
        print("[*] Dumping flash, pass 1/2 ...")
        f1 = dump_flash(port)
        if f1[:16] != KNOWN_VEC:
            print(f"[-] Sector-0 self-check FAILED: {f1[:16].hex(' ')}")
            print("    Alignment is off; not writing. Try a lower --freq.")
            return 4
        print("[*] Dumping flash, pass 2/2 ...")
        f2 = dump_flash(port)

        same = hashlib.sha256(f1).digest() == hashlib.sha256(f2).digest()
        print(f"[{'+' if same else '-'}] Two passes "
              f"{'match' if same else 'DIFFER (bus flake; consider lower --freq)'}")

        stored = int.from_bytes(f1[CRC_REGION:FLASH_SIZE], "big")
        calc = zw_crc32(f1[:CRC_REGION])
        if stored == 0xFFFFFFFF:
            crc_ok = None  # n/a: CRC slot never programmed by this image
            print("[*] On-chip CRC-32 slot is unprogrammed (0xFFFFFFFF) -- this "
                  "image doesn't use it; integrity rests on the two-pass match "
                  "and the sector-0 self-check.")
        else:
            crc_ok = stored == calc
            print(f"[*] On-chip CRC-32 stored=0x{stored:08x} "
                  f"computed=0x{calc:08x}"
                  f"  -> {'MATCH (byte-perfect)' if crc_ok else 'MISMATCH'}")

        flash_path = os.path.join(OUT_DIR, "sd3502_internal.bin")
        with open(flash_path, "wb") as fh:
            fh.write(f1)
        print(f"[+] wrote {flash_path} ({len(f1)} bytes)"
              f"  sha256={hashlib.sha256(f1).hexdigest()}")

        print("[*] Dumping NVR (0x09..0xFF) ...")
        nvr = dump_nvr(port)
        nvr_path = os.path.join(OUT_DIR, "sd3502_nvr.bin")
        with open(nvr_path, "wb") as fh:
            fh.write(nvr)
        print(f"[+] wrote {nvr_path} ({len(nvr)} bytes, base addr 0x09)"
              f"  sha256={hashlib.sha256(nvr).hexdigest()}")

        print("\n=== DONE ===")
        return 0 if (same and crc_ok is not False) else 5

    finally:
        if args.release_reset:
            print("[*] Releasing RESET_N (D4 high) -- board will reboot.")
            gpio.write(RST)
        spi.close()


if __name__ == "__main__":
    sys.exit(main())
