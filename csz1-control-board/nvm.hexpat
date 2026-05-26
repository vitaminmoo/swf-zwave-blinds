#pragma description Somfy/SWF "CSZ1" Cellular Shade Radio (blind control board) - ZM5202 / Micron M25PE20, 256 KiB flash
#pragma endian big

// Shared SWF/Somfy Z-Wave types. Add the repo's shared/ folder under
// ImHex Extras -> Settings -> Folders; the file lives in
// shared/includes/swf_zwave_common.pat.
#include "swf_zwave_common.pat"

// =====================================================================
//  CSZ1 control board - Micron M25PE20 (JEDEC 20 80 12, 256 KiB).
//  Cert ZC10-16055081. Data in: 0x0000 header, 0x0F80 table,
//  0x1200..0x1266 config block. Everything else is 0xFF (erased).
//
//  Note: Z-Wave version 6.61.00, firmware 187.65:1.09 and icon 0x1A00
//  are NOT here - they live in the ZW0500 internal firmware ROM.
// =====================================================================

ProtocolRegion<0x120> proto_header @ 0x0000;
ProtocolRegion<0x20>  proto_table  @ 0x0F80;
DeviceIdentity        device       @ 0x121A;
SerialNumber          serial       @ 0x1230;   // "5126732A003"
ManufacturerSpecific  mfg          @ 0x1256;   // 0x026E / 0x6783 / "CS" / "Z1"
