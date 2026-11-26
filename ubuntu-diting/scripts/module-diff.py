#!/usr/bin/env python3
"""Which modules differ in code between two builds of the same kernel tree.

usage: module-diff.py OLD_TREE NEW_TREE [LIST_FILE]

OLD_TREE and NEW_TREE are module trees (what is under kernel/ in a package's
lib/modules/<release>/). Compares every .ko present in both trees section by
section, leaving out the sections that differ between two builds of the same
code (the build id, the comment, BTF). A module whose code differs may have
been compiled against another layout of the kernel's structures, and then
does not fit the kernel of the other build: run this when the configuration
changed, before a kernel built with it is put on a phone that keeps the
modules of the package before.

Prints the counts and the directories, and writes the paths of the modules
that differ, relative to the trees, to LIST_FILE (one per line), for tar -T.
"""
import collections
import os
import struct
import sys

# Sections that differ between two builds of the same code.
SKIP = {".note.gnu.build-id", ".comment", ".BTF", ".BTF.base", ".llvm_addrsig",
        ".note.Linux", ".note.GNU-stack", "__versions", ".symtab", ".strtab",
        "__jump_table", "__bug_table", "__dyndbg_sites", "__tracepoints_ptrs",
        "__tracepoints_strings", "__tracepoint_iter", "__kcrctab"}
# The lines of .modinfo that say what a module needs or provides.
MODINFO_KEYS = (b"depends=", b"alias=", b"vermagic=", b"parm=", b"intree=", b"license=")


def sections(path):
    """ELF section name -> bytes, without the sections in SKIP."""
    d = open(path, "rb").read()
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    entsize, num = struct.unpack_from("<HH", d, 0x3a)
    stroff = struct.unpack_from("<Q", d, shoff + struct.unpack_from("<H", d, 0x3e)[0] * entsize + 0x18)[0]
    out = {}
    for i in range(num):
        s = d[shoff + i * entsize: shoff + (i + 1) * entsize]
        name, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", s)
        if typ in (0, 8):  # NULL, NOBITS
            continue
        nm = d[stroff + name: d.index(b"\0", stroff + name)].decode()
        if nm not in SKIP:
            out[nm] = d[off: off + size]
    return out


def modinfo(path):
    """The key -> values of .modinfo that matter to depmod and the loader."""
    out = {}
    d = open(path, "rb").read()
    for line in d.split(b"\0"):
        for key in MODINFO_KEYS:
            if line.startswith(key):
                k, _, v = line.partition(b"=")
                out.setdefault(k.decode(), set()).add(v.decode(errors="replace"))
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    old, new = sys.argv[1], sys.argv[2]
    list_file = sys.argv[3] if len(sys.argv) > 3 else None
    same = changed = 0
    groups = collections.Counter()
    changed_list = []
    for root, _, files in os.walk(new):
        for f in files:
            if not f.endswith(".ko"):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, new)
            op = os.path.join(old, rel)
            if not os.path.exists(op):
                continue
            if sections(op) == sections(path) and modinfo(op) == modinfo(path):
                same += 1
            else:
                changed += 1
                groups["/".join(rel.split("/")[:2])] += 1
                changed_list.append(rel)
    print("modules in both builds: %d; identical (build id aside): %d; different: %d"
          % (same + changed, same, changed))
    print("different, by directory:", " ".join("%s:%d" % kv for kv in groups.most_common(45)))
    if list_file:
        open(list_file, "w").write("\n".join(sorted(changed_list)) + "\n")
        print("written to", list_file)


if __name__ == "__main__":
    main()
