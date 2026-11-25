#!/usr/bin/env python3
"""Dump the QMI IDL tables of an Android vendor library: for every
*_qmi_idl_service_object_* symbol the message ids, and the raw bytes of the
TLV descriptors of every message.

    idl_dump.py LIBRARY [SERVICE-NAME ...]

The layout follows include/qmi_idl_lib_internal.h of Qualcomm's qmi-framework.
"""
import re
import struct
import sys

SHT_NOBITS, SHT_SYMTAB, SHT_RELA, SHT_DYNSYM = 8, 2, 4, 11
R_AARCH64_ABS64, R_AARCH64_GLOB_DAT, R_AARCH64_RELATIVE = 257, 1025, 1027
KIND = ("request", "response", "indication", "kind3")
SERVICE_OBJECT = re.compile(r"^[a-z0-9]+_qmi_idl_service_object_v[0-9]+$")


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
        self.symbols = []           # (name, address, size)
        self.tables = {}            # symbol table section index -> [(address, size)]
        for index, section in enumerate(self.sections):
            if section[1] not in (SHT_SYMTAB, SHT_DYNSYM):
                continue
            strings = self.sections[section[6]]
            entries = []
            for offset in range(section[4], section[4] + section[5], 24):
                name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", head, offset)
                start = strings[4] + name
                self.symbols.append((head[start:head.index(b"\0", start)].decode("ascii", "replace"), value, size))
                entries.append(value)
            self.tables[index] = entries
        self.relocations = {}       # where -> (kind, symbol table, symbol, addend)
        for section in self.sections:
            if section[1] != SHT_RELA:
                continue
            for offset in range(section[4], section[4] + section[5], 24):
                where, info, addend = struct.unpack_from("<QQq", head, offset)
                self.relocations[where] = (info & 0xFFFFFFFF, section[6], info >> 32, addend)

    def offset(self, address):
        for section in self.sections:
            if section[1] != SHT_NOBITS and section[3] <= address < section[3] + section[5]:
                return section[4] + address - section[3]
        raise KeyError("no section holds address 0x%x" % address)

    def read(self, address, size):
        offset = self.offset(address)
        return self.data[offset:offset + size]

    def pointer(self, address):
        """the pointer stored at address, with its relocation applied"""
        if address in self.relocations:
            kind, table, symbol, addend = self.relocations[address]
            if kind == R_AARCH64_RELATIVE:
                return addend
            if kind in (R_AARCH64_ABS64, R_AARCH64_GLOB_DAT):
                return self.tables[table][symbol] + addend
            raise KeyError("relocation of type %d at 0x%x" % (kind, address))
        return struct.unpack("<Q", self.read(address, 8))[0]

    def object(self, name):
        return next(symbol for symbol in self.symbols if symbol[0] == name)


def halves(blob):
    return struct.unpack("<%dH" % (len(blob) // 2), blob[:len(blob) // 2 * 2])


def is_service_object(symbol):
    """an exported 72 byte <name>_qmi_idl_service_object_v<n>, not a function mentioning the type"""
    return SERVICE_OBJECT.match(symbol[0]) is not None and symbol[2] == 72


def dump(elf, name):
    base = elf.object(name)[1]
    library, idl, service, longest = struct.unpack("<IIII", elf.read(base, 16))
    counts = halves(elf.read(base + 16, 8))
    # 24 bytes of header, a table of message ids per kind, the type table, the minor version, the parent
    tables = [elf.pointer(base + 24 + 8 * kind) for kind in range(3)]
    types = elf.pointer(base + 48)
    minor = struct.unpack("<I", elf.read(base + 56, 4))[0]
    n_types, n_messages, n_referenced = struct.unpack("<HHB", elf.read(types, 5))
    print("%s: service 0x%x, idl %d.%d, library %d, longest message %d bytes; %s; %d types, %d messages, %d referenced tables" % (
        name, service, idl, minor, library, longest,
        ", ".join("%d %s%s" % (count, KIND[kind], "" if count == 1 else "s") for kind, count in enumerate(counts[:3]) if count),
        n_types, n_messages, n_referenced))
    messages = []
    p_messages = elf.pointer(types + 16)
    for index in range(n_messages):
        messages.append((struct.unpack("<I", elf.read(p_messages + 16 * index, 4))[0], elf.pointer(p_messages + 16 * index + 8)))
    for kind in range(3):
        if not counts[kind]:
            continue
        print("  %s:" % KIND[kind])
        for index in range(counts[kind]):
            message_id, table_index, longest = struct.unpack("<HHH", elf.read(tables[kind] + 6 * index, 6))
            if table_index >= n_messages:       # described in a table this object only refers to
                print("    0x%04x  at most %4d on the wire, descriptor in a referenced table (%d)" % (message_id, longest, table_index))
                continue
            size, data = messages[table_index]
            print("    0x%04x  c struct %4d bytes, at most %4d: %s" % (message_id, size, longest, bytes(elf.read(data, 48)).hex(" ")))


def main(arguments):
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 2
    elf = Elf(arguments[0])
    names = arguments[1:] or [symbol[0] for symbol in elf.symbols if is_service_object(symbol)]
    for name in names:
        dump(elf, name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
