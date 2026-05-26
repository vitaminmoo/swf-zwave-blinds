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
//  Same record layout as the CSZ1 control board, relocated near the
//  end of the chip.
// =====================================================================

ProtocolRegion<0x20>  proto_header @ 0x0000;
SerialNumber          serial       @ 0x299C;   // "5126726A006" (preceded by a 0x42 'B' marker byte)
ManufacturerSpecific  mfg          @ 0x29B6;   // 0x026E / 0x5741 "WA" / "VC" / "Z1"

// DeviceIdentity for the remote is not placed: the 8 identity-looking
// bytes near 0x298A-0x2992 don't align cleanly with the CSZ1 layout,
// and a remote may store identity differently. Uncomment and adjust the
// offset once confirmed (e.g. by diffing a second VCZ1 dump):
//
// DeviceIdentity device @ 0x298A;   // [guess] boundary unconfirmed
