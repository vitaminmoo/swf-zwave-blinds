#pragma description Somfy/SWF "CSZ1" Cellular Shade Radio (blind control board) - ZM5202 / Micron M25PE20, 256 KiB flash
#pragma endian big

// Shared SWF/Somfy Z-Wave types. Add the repo's shared/ folder under
// ImHex Extras -> Settings -> Folders; the file lives in
// shared/includes/swf_zwave_common.pat.
#include "swf_zwave_common.pat"

// =====================================================================
//  CSZ1 control board - Micron M25PE20 (JEDEC 20 80 12, 256 KiB).
//  Cert ZC10-16055081. Data in: 0x0000 header, 0x0F80 table,
//  0x1200..0x1268 config block. Everything else is 0xFF (erased).
//
//  Note: Z-Wave version 6.61.00, firmware 187.65:1.09 and icon 0x1A00
//  are NOT here - they live in the SD3502 internal firmware ROM.
//
//  Firmware-default map (from the SD3502 init table, Ghidra; opcode
//  `E0 <len> 02 <addr-BE> <bytes>`). These bytes are written to NVM at
//  boot, so they are compile-time constants, not per-unit data:
//      0x1210  00 44
//      0x124F  00 44 04 0B 02
//      0x1254  00 13
//      0x1256  02 6E 67 83 43 53 5A 31 0B 02 04 21   <- mfr-specific blob
//      0x1262  00 13 FF 0B 02
//      0x1267  00 00
//  Per-unit (NOT in the firmware table): the serial @ 0x1230 and the
//  0x42-bracketed identity blob @ 0x1217..0x1221.
// =====================================================================

ProtocolRegion<0x120> proto_header @ 0x0000;
ProtocolRegion<0x20>  proto_table  @ 0x0F80;

// Per-unit identity blob: marker, then 9 bytes (55 08 | fc f6 4a 97 | ee
// 9e cf), then marker. Only the Home-ID-looking 4 bytes are typed; the
// 0x1218-0x1219 and 0x121E-0x1220 bytes are left unmodeled (role unknown).
Marker       id_marker_a  @ 0x1217;
HomeId       home_id      @ 0x121A;   // [likely] fc f6 4a 97
Marker       id_marker_b  @ 0x1221;

SerialNumber serial       @ 0x1230;   // "5126732A003" (per-unit, factory)

// Firmware-constant manufacturer-specific blob (0x026E / 0x6783 / "CS" /
// "Z1") plus the 4 trailing default bytes (0B 02 04 21).
ManufacturerSpecific mfg  @ 0x1256;
