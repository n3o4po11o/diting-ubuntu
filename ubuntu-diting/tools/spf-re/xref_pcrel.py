#!/usr/bin/env python3
"""Find pc-relative references to target VAs in llvm-objdump dumps.

Handles: `rN = add(pc,##imm)` / `mem[ub](pc+##imm)` etc. Hexagon PC-relative
values are packet-start based; we also test per-instruction addresses and
flag which interpretation hit.

Usage: xref_pcrel.py <dump.txt> [more dumps...]
"""
import re
import sys

TARGETS = {
    0xB07685EA: "str:Inside the audio Image Main function",
    0xB0768621: "str:Calling AudioPD coremain",
    0xB076863B: "str:enabling elite framework",
    0xB0768655: "str:Core Init for audio image done",
    0xF080E0B4: "str:GPR INIT START",
    0xF02C2ACB: "str:Protection Domain Launched",
}

line_re = re.compile(r"^([0-9a-f]+):\s+(.*)$")
imm_re = re.compile(r"(pc\s*\+)?##(0x[0-9a-f]+)")


def main():
    for path in sys.argv[1:]:
        packet_start = None
        last_addr = None
        for lineno, raw in enumerate(open(path, errors="replace"), 1):
            m = line_re.match(raw)
            if not m:
                continue
            addr = int(m.group(1), 16)
            rest = m.group(2)
            if "{" in rest:
                packet_start = addr
            for im in imm_re.finditer(rest):
                imm = int(im.group(2), 16)
                pcrel = bool(im.group(1)) or "add(pc" in rest
                for base_name, base in (("pkt", packet_start), ("inst", addr)):
                    if base is None:
                        continue
                    va = base + imm if pcrel else imm
                    if va in TARGETS:
                        print(f"{path}:{lineno} 0x{addr:08x} (pkt 0x{packet_start:08x}) "
                              f"{'PCREL' if pcrel else 'ABS'} -> 0x{va:08x} {TARGETS[va]}")
                        print(f"    {raw.rstrip()}")


if __name__ == "__main__":
    main()
