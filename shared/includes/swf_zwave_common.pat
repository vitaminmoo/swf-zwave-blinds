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
//  The config block on both devices contains 0x0B-length-prefixed
//  records (TLV-like): a 0x0B (=11) byte followed by exactly 11 bytes,
//  then the next 0x0B. The manufacturer-specific data below lives
//  inside one such record. The TLV grammar isn't fully confirmed from
//  the dumps available, so records aren't modeled as a list yet.
//
//  Confidence legend used in field comments:
//    [confirmed] cross-checked vs Z-Wave Alliance certs
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

// Null-terminated device serial number (e.g. "5126732A003").
struct SerialNumber {
    char value[] [[color("BA68C8"),
        comment("[confirmed] device serial number, null-terminated")]];
};

// 8 bytes of per-unit data: first 4 most likely the Z-Wave Home ID,
// trailing 4 look like key/seed material (unconfirmed).
struct DeviceIdentity {
    std::mem::Bytes<4> home_id [[color("F5C518"),
        comment("[likely] Z-Wave Home ID (set when included into a network)")]];
    std::mem::Bytes<4> secret  [[color("E58F00"),
        comment("[guess] key / seed material - unconfirmed")]];
};

// Command Class 0x72 (Manufacturer Specific) record, big-endian.
// Layout is mfr / a 16-bit field / product type / product id.
// Verified against Z-Wave Alliance certs ZC10-16055081 (CSZ1) and
// ZC10-16055082 (VCZ1).
struct ManufacturerSpecific {
    ManufacturerId manufacturer_id [[color("4FC3F7"),
        comment("[confirmed] 0x026E = Springs Window Fashions")]];
    u16 field2 [[color("9E9E9E"), format("format_ascii_u16"),
        comment("[guess] role unknown; CSZ1=0x6783, VCZ1=0x5741 (\"WA\")")]];
    u16 product_type_id [[color("81C784"), format("format_ascii_u16"),
        comment("[confirmed] Product Type (CSZ1 0x4353 \"CS\", VCZ1 0x5643 \"VC\")")]];
    u16 product_id [[color("81C784"), format("format_ascii_u16"),
        comment("[confirmed] Product ID 0x5A31 = \"Z1\"")]];
};
