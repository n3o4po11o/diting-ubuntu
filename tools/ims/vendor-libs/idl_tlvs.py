#!/usr/bin/env python3
"""Decode the TLV descriptors of QMI IDL messages in an Android vendor library.

    idl_tlvs.py LIBRARY SERVICE-OBJECT MSGID-HEX [MSGID-HEX ...]

For each message id (requests, then responses, then indications) every TLV of
its C structure: type, element type, flags, and for strings, arrays and
nested structures the size and the referenced type. The layout of the tables
follows include/qmi_idl_lib_internal.h of Qualcomm's qmi-framework.
"""
import struct
import sys

SHT_NOBITS, SHT_SYMTAB, SHT_DYNSYM, SHT_RELA = 8, 2, 11, 4
ELEMENTS = ("u8", "u16", "u32", "u64", "enum8", "enum16", "string", "struct")
KIND = ("request", "response", "indication")
LAST, EXTENDED, ARRAY, SIZE_16, VARIABLE = 0x80, 0x40, 0x40, 0x20, 0x10


class Elf:
    """the little an ELF64 reader needs to follow relocated pointers"""

    def __init__(self, path):
        self.data = open(path, "rb").read()
        head = self.data
        if head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1:
            raise SystemExit("%s: not a little-endian ELF64 file" % path)
        shoff = struct.unpack_from("<Q", head, 0x28)[0]
        shentsize, shnum = struct.unpack_from("<HH", head, 0x3A)
        self.sections = [struct.unpack_from("<IIQQQQIIQQ", head, shoff + i * shentsize) for i in range(shnum)]
        self.symbols = []
        for section in self.sections:
            if section[1] not in (SHT_SYMTAB, SHT_DYNSYM):
                continue
            strings = self.sections[section[6]]
            for offset in range(section[4], section[4] + section[5], 24):
                name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", head, offset)
                start = strings[4] + name
                self.symbols.append((head[start:head.index(b"\0", start)].decode("ascii", "replace"), value, size))
        # the libraries carry RELR or Android packed relocations: the addresses are in place

    def offset(self, address):
        for section in self.sections:
            if section[1] != SHT_NOBITS and section[3] <= address < section[3] + section[5]:
                return section[4] + address - section[3]
        raise KeyError("no section holds address 0x%x" % address)

    def read(self, address, size):
        offset = self.offset(address)
        return self.data[offset:offset + size]

    def u16(self, address):
        return struct.unpack("<H", self.read(address, 2))[0]

    def u32(self, address):
        return struct.unpack("<I", self.read(address, 4))[0]

    def pointer(self, address):
        return struct.unpack("<Q", self.read(address, 8))[0]

    def address(self, name):
        return next(symbol[1] for symbol in self.symbols if symbol[0] == name)


def decode(data, limit=64):
    """the TLVs described by a byte stream of TLV descriptors"""
    out, at = [], 0
    while at < len(data) and len(out) < limit:
        first = data[at]
        at += 1
        if first == 0:               # TLV type 0 does not exist: the descriptors have ended
            break
        kind = None
        if first & EXTENDED:
            kind, at = data[at], at + 1
        else:
            kind = first & 0x0F
        element, at = data[at], at + 1
        code = element & 0x07
        offset, at = data[at], at + 1
        if element & 0x80:
            offset = offset | (data[at] << 8)
            at += 1
        entry = {"tlv": kind, "optional_flags": first & 0x3F & ~0x0F if not first & EXTENDED else first & 0x1F,
                 "element": ELEMENTS[code], "offset": offset, "last": bool(first & LAST)}
        if element & ARRAY or code == 6:
            if element & SIZE_16:
                entry["size"], at = struct.unpack_from("<H", data, at)[0], at + 2
            else:
                entry["size"], at = data[at], at + 1
            if element & VARIABLE:
                entry["length_at"], at = data[at], at + 1
        if code == 7:
            entry["type"], at = struct.unpack_from("<H", data, at)[0], at + 2
        out.append(entry)
        if first & LAST:
            break
    return out


def show(entry):
    text = "TLV 0x%02x  %s" % (entry["tlv"], entry["element"])
    if "size" in entry:
        text += "[%d]" % entry["size"]
    if entry["element"] == "struct":
        text += " (type table %d, type %d)" % (entry["type"] >> 8, entry["type"] & 0xFF)
    return text


def main(arguments):
    if len(arguments) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    elf = Elf(arguments[0])
    base = elf.address(arguments[1])
    service = struct.unpack("<I", elf.read(base + 8, 4))[0]
    counts = struct.unpack("<4H", elf.read(base + 16, 8))
    tables = [elf.pointer(base + 24 + 8 * kind) for kind in range(3)]
    types = elf.pointer(base + 48)
    n_types, n_messages = struct.unpack("<HH", elf.read(types, 4))
    p_types, p_messages = elf.pointer(types + 8), elf.pointer(types + 16)
    messages = [(elf.u32(p_messages + 16 * i), elf.pointer(p_messages + 16 * i + 8)) for i in range(n_messages)]
    type_sizes = [elf.u32(p_types + 16 * i) for i in range(n_types)]
    print("%s: service 0x%02x, %d types, %d messages" % (arguments[1], service, n_types, n_messages))
    wanted = [int(a, 16) for a in arguments[2:]]
    for kind in range(3):
        for index in range(counts[kind]):
            message_id, table_index, longest = struct.unpack("<HHH", elf.read(tables[kind] + 6 * index, 6))
            if message_id not in wanted:
                continue
            if table_index >= n_messages:
                print("0x%04x %s: descriptor in a referenced table (%d)" % (message_id, KIND[kind], table_index))
                continue
            size, data = messages[table_index]
            if longest == 0 and size <= 1:   # an empty message: its pointer leads into other data
                print("0x%04x %-11s no TLVs" % (message_id, KIND[kind]))
                continue
            print("0x%04x %-11s c struct %d bytes, at most %d on the wire:" % (message_id, KIND[kind], size, longest))
            for entry in decode(elf.read(data, 256)):
                note = ""
                if entry["element"] == "struct" and entry["type"] & 0xFF < len(type_sizes):
                    note = "  (%d bytes)" % type_sizes[entry["type"] & 0xFF]
                print("    %-40s at C offset %-3d%s%s" % (
                    show(entry), entry["offset"], note, "  last" if entry["last"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
