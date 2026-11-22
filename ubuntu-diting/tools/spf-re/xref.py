#!/usr/bin/env python3
"""Scan disassembly dumps + raw firmware for references to target VAs.

Usage: xref.py <fw.mbn> <dump1.txt> [dump2.txt ...]
Targets are baked in (SPF init strings) — edit TARGETS to extend.
"""
import glob
import os
import struct
import sys

TARGETS = {
    0xB07685EA: "str:Inside the audio Image Main function",
    0xB0768621: "str:Calling AudioPD coremain",
    0xB076863B: "str:enabling elite framework",
    0xB0768655: "str:Core Init for audio image done",
    0xF080E0B4: "str:GPR INIT START (gpr_init_adsp_kernel_wrapper.c)",
    0xF02C2ACB: "str:Protection Domain Launched",
}

# string pool neighborhood: also flag any imm landing in 0xb0768000-0xb0768900
POOL_LO, POOL_HI = 0xB0768000, 0xB0768A00


def main():
    fw = open(sys.argv[1], "rb").read()

    print("== raw 4-byte pointer scan (whole file, any alignment) ==")
    for va, name in TARGETS.items():
        pat = struct.pack("<I", va)
        i = fw.find(pat)
        hits = []
        while i != -1 and len(hits) < 8:
            hits.append(i)
            i = fw.find(pat, i + 1)
        if hits:
            print(f"  {name}: file offsets {[hex(h) for h in hits]}")
        else:
            print(f"  {name}: no raw pointer")

    print("\n== disassembly immediate scan ==")
    for path in sys.argv[2:]:
        for line in open(path, errors="replace"):
            # immediates appear as ##0x... or #0x... operands
            for m_start in [i for i in range(len(line)) if line.startswith("#0x", i)]:
                hexpart = line[m_start + 3:m_start + 3 + 8]
                try:
                    val = int(hexpart, 16)
                except ValueError:
                    continue
                if val in TARGETS or (POOL_LO <= val < POOL_HI and val % 4 == 0):
                    va_name = TARGETS.get(val, f"pool+0x{val - 0xB0768000:x}")
                    print(f"  [{os.path.basename(path)}] {line.rstrip()}   <<< {va_name}")


if __name__ == "__main__":
    main()
