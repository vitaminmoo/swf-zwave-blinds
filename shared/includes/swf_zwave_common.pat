#pragma once

// =====================================================================
//  Shared types for Somfy / Springs Window Fashions (Mfr 0x026E)
//  Z-Wave 500-series devices that store config in external memory.
//
//  Used by:
//    csz1-control-board/nvm.hexpat  (CSZ1, ZM5202, M25PE20 flash)
//    vcz1-remote/nvm.hexpat         (VCZ1, ZM5101, CAV25256 EEPROM)
//
//  Both images are mostly erased; data clusters in one config block.
//
//  STRUCTURE (from the CSZ1 SD3502 firmware, Ghidra):
//  The config block is NOT a self-describing in-NVM TLV (an earlier
//  "0x0B-length-prefixed records" guess was wrong - the stray 0x0B bytes
//  are just values inside default blobs). Instead the bytes come from two
//  sources:
//    1. Firmware DEFAULTS, written at boot by an init routine that walks
//       an opcode table in the SD3502 firmware (CODE ~0x2200-0x2360).
//       NVM records are `E0 <len> 02 <addr:u16 BE> <len bytes>`. On the
//       CSZ1 the six records target 0x1210/0x124F/0x1254/0x1256/0x1262/
//       0x1267 - including the whole manufacturer-specific blob below,
//       so mfr/field2/product-type/product-id are COMPILE-TIME CONSTANTS.
//    2. Per-unit FACTORY / INCLUSION data, NOT in the firmware table:
//       the serial string and the 0x42-bracketed identity blob (Home ID
//       + seed). These differ per device and are written at manufacture /
//       network inclusion.
//  See csz1-control-board/README.md and docs for the firmware analysis.
//
//  Confidence legend used in field comments:
//    [confirmed] cross-checked vs Z-Wave Alliance certs and/or firmware
//    [likely]    strong inference
//    [guess]     unverified
// =====================================================================

#include <std/mem>
#include <std/string>
#include <std/core>

// Renders a big-endian u16 as both its hex value and its two ASCII
// bytes, e.g. 0x4353 -> 0x4353 "CS". The vendor picks product type/id
// values so the SKU spells out in a hex dump.
fn format_ascii_u16(u16 value) {
    return std::format("0x{:04X} \"{}{}\"", value, char(value >> 8), char(value & 0xFF));
};

enum ManufacturerId : u16 {
    SpringsWindowFashions = 0x026E,
};

// Arbitrary-size protocol-managed region, left raw (layout unconfirmed).
// Scattered 0xFE bytes are the nvm module's "unwritten" markers.
struct ProtocolRegion<auto Size> {
    std::mem::Bytes<Size> data [[color("455A64"),
        comment("[guess] protocol-managed NVM; layout unconfirmed")]];
};

// Single 0x42 ('B') byte that brackets the per-unit identity blob (and
// precedes the serial on the VCZ1). [likely] a per-field NVM marker.
struct Marker {
    u8 value [[color("607D8B"), comment("[likely] 0x42 'B' NVM field marker")]];
};

// Null-terminated device serial number (e.g. "5126732A003").
// Per-unit factory data; NOT in the firmware default table.
struct SerialNumber {
    char value[] [[color("BA68C8"),
        comment("[confirmed] device serial number, null-terminated")]];
};

// Per-unit identity blob, bracketed by 0x42 markers. NOT firmware-
// defaulted (assigned at network inclusion). The internal split is
// unconfirmed and differs in length between devices (CSZ1 = 9 bytes,
// VCZ1 = 8), so only the Home ID is typed; place it at the offset that
// looks like a Home ID and leave the rest opaque.
struct HomeId {
    std::mem::Bytes<4> bytes [[color("F5C518"),
        comment("[likely] Z-Wave Home ID (assigned when included into a network)")]];
};

// Command Class 0x72 (Manufacturer Specific) values, big-endian, with a
// vendor-specific field2 wedged between mfr and product-type. The whole
// blob is a firmware compile-time constant (CSZ1: const @ CODE:2303),
// verified against Z-Wave Alliance certs ZC10-16055081 (CSZ1) and
// ZC10-16055082 (VCZ1).
struct ManufacturerSpecific {
    ManufacturerId manufacturer_id [[color("4FC3F7"),
        comment("[confirmed] 0x026E = Springs Window Fashions")]];
    u16 field2 [[color("9E9E9E"), format("format_ascii_u16"),
        comment("[confirmed] fixed per-product firmware constant; semantics unknown. CSZ1=0x6783, VCZ1=0x5741 (\"WA\")")]];
    u16 product_type_id [[color("81C784"), format("format_ascii_u16"),
        comment("[confirmed] Product Type (CSZ1 0x4353 \"CS\", VCZ1 0x5643 \"VC\")")]];
    u16 product_id [[color("81C784"), format("format_ascii_u16"),
        comment("[confirmed] Product ID 0x5A31 = \"Z1\"")]];
    // Trailing firmware-default bytes (0x0B 0x02 0x04 0x21 on both
    // devices) - opaque SDK config, not part of the CC 0x72 triple.
    std::mem::Bytes<4> trailing [[color("455A64"),
        comment("[guess] firmware-default config bytes that follow the mfr blob")]];
};
