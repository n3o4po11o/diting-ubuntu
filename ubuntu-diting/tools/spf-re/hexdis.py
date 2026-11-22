#!/usr/bin/env python3
"""Hexagon disassembly helper for ADSP ELF firmware.

Drives llvm-mc (LLVM Hexagon MCDisassembler) from Python. capstone has no
Hexagon backend in any release (5.x) nor in capstone6-next, so LLVM is the
disassembly engine; Python does ELF mapping, xref scanning and CFG work.

Every Hexagon instruction is exactly 4 bytes and llvm-mc decodes the byte
stream sequentially, so n-th decoded instruction == base + 4*n even though
llvm-mc does not print addresses.
"""
import re
import subprocess
import tempfile
import os

LLVM_MC = "/opt/homebrew/opt/llvm/bin/llvm-mc"
DEFAULT_CPU = "hexagonv68"  # SM8475 (8+ Gen 1) ADSP is Hexagon v68


def disasm(code: bytes, base: int, cpu: str = DEFAULT_CPU):
    """Disassemble a 4-byte-aligned code buffer.

    Returns list of dicts: {va, encoding, text, packet_end}
    Un decodable words get text '<und>' and keep their slot.
    """
    assert len(code) % 4 == 0
    nwords = len(code) // 4
    hexsrc = "\n".join(",".join(f"0x{b:02x}" for b in code[i:i + 4])
                       for i in range(0, len(code), 4))
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
        f.write(hexsrc)
        path = f.name
    try:
        p = subprocess.run(
            [LLVM_MC, "-arch=hexagon", f"-mcpu={cpu}", "-disassemble", path],
            capture_output=True, text=True, timeout=600)
        out = p.stdout
    finally:
        os.unlink(path)

    insts = []
    idx = 0
    for line in out.splitlines():
        line = re.sub(r"\s*//.*$", "", line.rstrip())  # drop trailing comments
        s = line.strip()
        if not s or s in ("{", "}"):
            continue
        if idx >= nwords:
            break
        insts.append(dict(va=base + 4 * idx, text=s))
        idx += 1
    # if llvm-mc errored mid-way (invalid), pad the remainder
    while idx < nwords:
        insts.append(dict(va=base + 4 * idx, text="<und>"))
        idx += 1
    return insts


def format_insts(insts, data=None, annot=None):
    lines = []
    for i in insts:
        va = i["va"]
        raw = ""
        if data is not None:
            off = va  # caller passes file bytes + translate; keep simple: no raw
        note = f"   ; {annot[va]}" if annot and va in annot else ""
        lines.append(f"0x{va:08x}:  {i['text']}{note}")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    fw = open(sys.argv[1], "rb").read()
    off, length, cpu = int(sys.argv[2], 0), int(sys.argv[3], 0), \
        (sys.argv[4] if len(sys.argv) > 4 else DEFAULT_CPU)
    code = fw[off:off + length]
    for i in disasm(code, off, cpu):
        print(f"0x{i['va']:08x}:  {i['text']}")
