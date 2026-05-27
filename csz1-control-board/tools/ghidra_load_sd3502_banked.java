// Load the CSZ1 SD3502 (Sigma/SiLabs 500-series, banked 8051) internal-flash dump.
//
// Ghidra's 8051 has a 16-bit (64 KiB) code space, but sd3502_internal.bin is
// 128 KiB. The firmware is a Keil L51 *banked* image: a 32 KiB common region
// (0x0000-0x7FFF, present in every bank) plus a 32 KiB window (0x8000-0xFFFF)
// that is paged across three banks via SFR 0xFF bits [5:4].
//
//   CPU window      file offset        Ghidra block
//   0x0000-0x7FFF   0x00000-0x07FFF    CODE (common)
//   0x8000-0xFFFF   0x08000-0x0FFFF    CODE (bank 0, base space)   <- bank field 1
//   0x8000-0xFFFF   0x10000-0x17FFF    BANK1 overlay               <- bank field 2
//   0x8000-0xFFFF   0x18000-0x1FFFF    BANK2 overlay               <- bank field 3
//
// This script (idempotent):
//   1. creates the BANK1/BANK2 overlays from the on-disk file,
//   2. labels the bank-select SFR (FLASH_BANK_SEL @ SFR:0xFF),
//   3. seeds disassembly at the reset + interrupt vectors and analyzes,
//   4. finds the L51 banked-call dispatchers + thunks and rewires every thunk
//      to a Ghidra thunk-function pointing at the real banked target, so callers
//      in the common region decompile straight through into the right bank.
//
// Import first as language 8051:BE:16:default (Raw Binary). Then run this.
//
//@category ZWave
//@keybinding
//@menupath
//@toolbar

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.plugin.core.analysis.AutoAnalysisManager;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;

public class ghidra_load_sd3502_banked extends GhidraScript {

    // field value in SFR 0xFF bits[5:4]  ->  bank number (0=base CODE, 1=BANK1, 2=BANK2)
    private static int fieldToBank(int orlConst) {
        int field = (orlConst >> 4) & 3;   // 0x90->1, 0xA0->2, 0xB0->3
        return field - 1;                  // -> 0, 1, 2
    }

    public void run() throws Exception {
        byte[] fw = Files.readAllBytes(Paths.get(currentProgram.getExecutablePath()));
        if (fw.length < 0x20000) {
            printerr("expected a >=128 KiB image, got " + fw.length + " bytes");
            return;
        }
        Memory mem = currentProgram.getMemory();
        AddressSpace code = currentProgram.getAddressFactory().getAddressSpace("CODE");

        // 1. overlays for banks 1 and 2 (bank 0 already lives in the base CODE block)
        makeOverlay(mem, "BANK1", code.getAddress(0x8000L), slice(fw, 0x10000, 0x18000));
        makeOverlay(mem, "BANK2", code.getAddress(0x8000L), slice(fw, 0x18000, 0x20000));

        // 2. label the bank-select SFR
        AddressSpace sfr = currentProgram.getAddressFactory().getAddressSpace("SFR");
        if (sfr != null) {
            try {
                currentProgram.getSymbolTable().createLabel(
                        sfr.getAddress(0xFFL), "FLASH_BANK_SEL", SourceType.USER_DEFINED);
            } catch (Exception e) { /* already labelled */ }
        }

        // 3. seed disassembly: reset (0x0000) + the 8051 IRQ vectors (0x03 + 8*n)
        AddressSet seeds = new AddressSet();
        seeds.add(code.getAddress(0x0000L));
        for (long v = 0x03; v <= 0x73; v += 8) seeds.add(code.getAddress(v));
        for (Address a : seeds.getAddresses(true)) currentProgram.getSymbolTable().addExternalEntryPoint(a);
        new DisassembleCommand(seeds, null, true).applyTo(currentProgram, monitor);
        analyze();

        // 4. find dispatchers + thunks in the common region and rewire them
        resolveThunks(fw, code);
        analyze();

        println("SD3502 banked load complete. Functions: " + currentProgram.getFunctionManager().getFunctionCount());
    }

    private void makeOverlay(Memory mem, String name, Address start, byte[] bytes) throws Exception {
        if (mem.getBlock(name) != null) { println(name + " already exists, skipping"); return; }
        MemoryBlock b = mem.createInitializedBlock(
                name, start, new ByteArrayInputStream(bytes), bytes.length, monitor, true /* overlay */);
        b.setRead(true); b.setWrite(false); b.setExecute(true);
        println("created overlay " + name + " @ " + b.getStart() + " (" + bytes.length + " bytes)");
    }

    private static byte[] slice(byte[] a, int from, int to) {
        byte[] r = new byte[to - from];
        System.arraycopy(a, from, r, 0, to - from);
        return r;
    }

    private void analyze() {
        AutoAnalysisManager aam = AutoAnalysisManager.getAnalysisManager(currentProgram);
        aam.reAnalyzeAll(null);
        aam.startAnalysis(monitor);
    }

    // Scan common (0x0000-0x7FFF) for the L51 bank dispatchers and the
    // "MOV DPTR,#target ; (A)JMP dispatcher" thunks, then wire each thunk to a
    // thunk-function pointing at the real banked target.
    private void resolveThunks(byte[] fw, AddressSpace code) {
        // dispatcher switch signature: E5 FF 54 CF 44 kk F5 FF  (A=FF; A&=CF; A|=kk; FF=A)
        // its entry (what thunks jump to) starts a few bytes earlier with: C0 67 74 hi C0 E0 C0 82 C0 83 75 67 ll
        java.util.HashMap<Integer, Integer> entryBank = new java.util.HashMap<>(); // entry addr -> bank
        for (int i = 0; i < 0x8000 - 13; i++) {
            if ((fw[i] & 0xFF) == 0xC0 && (fw[i + 1] & 0xFF) == 0x67 && (fw[i + 2] & 0xFF) == 0x74
                    && (fw[i + 4] & 0xFF) == 0xC0 && (fw[i + 5] & 0xFF) == 0xE0
                    && (fw[i + 6] & 0xFF) == 0xC0 && (fw[i + 7] & 0xFF) == 0x82
                    && (fw[i + 8] & 0xFF) == 0xC0 && (fw[i + 9] & 0xFF) == 0x83
                    && (fw[i + 10] & 0xFF) == 0x75 && (fw[i + 11] & 0xFF) == 0x67) {
                int sw = i + 13;
                if (sw + 8 <= 0x8000 && (fw[sw] & 0xFF) == 0xE5 && (fw[sw + 1] & 0xFF) == 0xFF
                        && (fw[sw + 2] & 0xFF) == 0x54 && (fw[sw + 3] & 0xFF) == 0xCF
                        && (fw[sw + 4] & 0xFF) == 0x44 && (fw[sw + 6] & 0xFF) == 0xF5
                        && (fw[sw + 7] & 0xFF) == 0xFF) {
                    entryBank.put(i, fieldToBank(fw[sw + 5] & 0xFF));
                }
            }
        }
        println("dispatchers found: " + entryBank.size());

        FunctionManager fm = currentProgram.getFunctionManager();
        AddressSpace[] bankSpace = {
                code,
                currentProgram.getAddressFactory().getAddressSpace("BANK1"),
                currentProgram.getAddressFactory().getAddressSpace("BANK2")
        };
        int linked = 0;
        for (int i = 0; i < 0x8000 - 5; i++) {
            if ((fw[i] & 0xFF) != 0x90) continue;          // MOV DPTR,#imm16
            int tgt = ((fw[i + 1] & 0xFF) << 8) | (fw[i + 2] & 0xFF);
            if (tgt < 0x8000) continue;                    // banked window only
            int op = fw[i + 3] & 0xFF;
            int dst;
            if ((op & 0x1F) == 0x01) {                     // AJMP (11-bit)
                int jaddr = i + 3, page = fw[i + 4] & 0xFF;
                dst = ((jaddr + 2) & 0xF800) | (((op & 0xE0) << 3) | page);
            } else if (op == 0x02) {                        // LJMP (16-bit)
                dst = ((fw[i + 4] & 0xFF) << 8) | (fw[i + 5] & 0xFF);
            } else {
                continue;
            }
            Integer bank = entryBank.get(dst);
            if (bank == null) continue;

            try {
                Address tgtAddr = bankSpace[bank].getAddress(tgt & 0xFFFFL);
                Function tf = fm.getFunctionAt(tgtAddr);
                if (tf == null && new CreateFunctionCmd(tgtAddr).applyTo(currentProgram, monitor)) {
                    tf = fm.getFunctionAt(tgtAddr);
                }
                if (tf != null && (tf.getName().startsWith("FUN_") || tf.getName().startsWith("SUB_"))) {
                    tf.setName(String.format("bank%d_%04x", bank, tgt), SourceType.USER_DEFINED);
                }
                Address thunkAddr = code.getAddress(i & 0xFFFFL);
                Function th = fm.getFunctionAt(thunkAddr);
                if (th == null && new CreateFunctionCmd(thunkAddr).applyTo(currentProgram, monitor)) {
                    th = fm.getFunctionAt(thunkAddr);
                }
                if (th != null && tf != null) {
                    th.setThunkedFunction(tf);
                    th.setName(String.format("jb%d_%04x", bank, tgt), SourceType.USER_DEFINED);
                    linked++;
                }
            } catch (Exception e) {
                printerr("thunk @ " + Integer.toHexString(i) + " -> " + Integer.toHexString(tgt) + ": " + e.getMessage());
            }
        }
        println("banked-call thunks resolved: " + linked);
    }
}
