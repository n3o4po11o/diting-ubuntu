#!/usr/bin/env python3
"""ADSP ELF (32-bit LE Hexagon QDSP6) parser: program headers + offset<->VA map.

No section headers in these MBN-style ELFs; everything is driven by phdrs.
Usage: elfmap.py <fw.mbn>            - dump phdr table
       elfmap.py <fw.mbn> <off>...   - map file offsets to VAs
"""
import struct
import sys

PT_LOAD = 1
PT_ARM = 0x70000000  # qdsp6 custom segment types may show up; we map any with filesz


def parse_phdrs(data: bytes):
    assert data[:4] == b"\x7fELF", "not an ELF"
    ei_class, ei_data = data[4], data[5]
    assert ei_class == 1 and ei_data == 1, "expected ELF32 LE"
    (e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
     e_ehsize, e_phentsize, e_phnum) = struct.unpack_from("<HHIIIIIHHH", data, 16)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack_from("<8I", data, off)
        segs.append(dict(idx=i, type=p_type, offset=p_offset, vaddr=p_vaddr,
                         paddr=p_paddr, filesz=p_filesz, memsz=p_memsz,
                         flags=p_flags, align=p_align))
    return dict(e_type=e_type, e_machine=e_machine, e_entry=e_entry,
                e_flags=e_flags, phnum=e_phnum, segs=segs)


def off2va(segs, off):
    for s in segs:
        if s["type"] == PT_LOAD and s["offset"] <= off < s["offset"] + s["filesz"]:
            return s["vaddr"] + (off - s["offset"])
    return None


def va2off(segs, va):
    for s in segs:
        if s["type"] == PT_LOAD and s["vaddr"] <= va < s["vaddr"] + s["filesz"]:
            return s["offset"] + (va - s["vaddr"])
    return None


def rwx(f):
    return ("R" if f & 4 else "-") + ("W" if f & 2 else "-") + ("X" if f & 1 else "-")


def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    hdr = parse_phdrs(data)
    t = {0: "NULL", 1: "LOAD", 2: "DYNAMIC", 6: "PHDR", 0x70000001: "QEDELF",
         0x6474e550: "GNU_EH_FRAME", 0x6474e551: "GNU_STACK", 0x6474e552: "GNU_RELRO"}
    print(f"ELF32 LE  type={hdr['e_type']} machine={hdr['e_machine']} "
          f"entry=0x{hdr['e_entry']:08x} phnum={hdr['phnum']} flags=0x{hdr['e_flags']:08x}")
    print(f"{'#':>2} {'type':<12} {'offset':>10} {'vaddr':>10} {'filesz':>10} "
          f"{'memsz':>10} {'flg':<4} {'align':>8}")
    for s in hdr["segs"]:
        name = t.get(s["type"], hex(s["type"]))
        print(f"{s['idx']:>2} {name:<12} 0x{s['offset']:08x} 0x{s['vaddr']:08x} "
              f"0x{s['filesz']:08x} 0x{s['memsz']:08x} {rwx(s['flags']):<4} 0x{s['align']:x}")
    for arg in sys.argv[2:]:
        off = int(arg, 0)
        print(f"file 0x{off:x} -> va 0x{off2va(hdr['segs'], off):08x} "
              f"str={data[off:off+48].split(b'\\x00')[0]!r}")


if __name__ == "__main__":
    main()
