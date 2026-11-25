#!/usr/bin/env python3
"""Show the disassembly lines that name a symbol, with the function around them.

    disasm_refs.py DISASSEMBLY REGEX [--all]

DISASSEMBLY is llvm-objdump -d -C output. Without --all only lines that take
an address (adrp, add) or branch are shown, i.e. the places that use the symbol.
"""
import re
import sys

LABEL = re.compile(r"^([0-9a-f]+) <(.+)>:$")
USES = re.compile(r"\b(adrp|add|bl|b|ldr|str)\b")


def main(arguments):
    if len(arguments) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    pattern = re.compile(arguments[1])
    everything = "--all" in arguments[2:]
    function = ""
    count = 0
    for line in open(arguments[0]):
        label = LABEL.match(line)
        if label:
            function = label.group(2)
            continue
        if not pattern.search(line):
            continue
        if not everything and not USES.search(line):
            continue
        count += 1
        print("%-72s | %s" % (function[:72], line.strip()[:120]))
    print("%d lines" % count, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
