#pragma description Somfy/SWF "VCZ1" Virtual Cord Control (2-button remote) - ZM5101 / Catalyst CAV25256, 32 KiB EEPROM
#pragma endian big

// Shared SWF/Somfy Z-Wave types. Add the repo's shared/ folder under
// ImHex Extras -> Settings -> Folders; the file lives in
// shared/includes/swf_zwave_common.pat.
#include "swf_zwave_common.pat"

// =====================================================================
//  VCZ1 two-button remote - Catalyst/ON CAV25256 (32 KiB SPI EEPROM,
//  no JEDEC RDID). Cert ZC10-16055082. Data in: 0x0000 header and the
//  0x2980..0x29C8 config block. Everything else is 0x00/0xFF.
//
//  Same layout as the CSZ1 control board, relocated near the end of the
//  chip. The VCZ1 firmware was not dumped, but the manufacturer blob and
//  its surrounding bytes are byte-for-byte the CSZ1 structure (only the
//  product constants differ), so the same firmware-default scheme applies
//  (see csz1-control-board/nvm.hexpat for the decoded init records).
//  Firmware-constant mfr blob @ 0x29B6; per-unit serial @ 0x299C and the
//  0x42-bracketed identity blob @ 0x2989..0x2992.
// =====================================================================

ProtocolRegion<0x20>  proto_header @ 0x0000;

// Per-unit identity blob: marker, 8 bytes (20 14 | e7 2e 93 2e | 9e 47),
// marker. Home-ID-looking 4 bytes typed at the same payload+2 offset as
// the CSZ1; surrounding bytes left unmodeled (role unknown).
Marker       id_marker_a  @ 0x2989;
HomeId       home_id      @ 0x298C;   // [likely] e7 2e 93 2e
Marker       id_marker_b  @ 0x2992;

Marker       serial_marker @ 0x299B;  // 0x42 'B' precedes the serial here
SerialNumber serial        @ 0x299C;  // "5126726A006" (per-unit, factory)

// Firmware-constant manufacturer-specific blob (0x026E / 0x5741 "WA" /
// "VC" / "Z1") plus the 4 trailing default bytes (0B 02 04 21).
ManufacturerSpecific mfg   @ 0x29B6;
