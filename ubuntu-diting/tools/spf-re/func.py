#!/usr/bin/env python3
"""Recover the Hexagon function containing a given address, from an
llvm-objdump dump file. Function start = nearest preceding allocframe
(or packet with ` = #0` frame setup), end = dealloc_return/jumpr r31.

Usage: func.py <dump.txt> <addr> [context]
"""
import re
import sys

line_re = re.compile(r"^([0-9a-f]+):\s+(.*)$")


def load(path):
    lines = []  # (addr, text)
    for raw in open(path, errors="replace"):
        m = line_re.match(raw)
        if m:
            lines.append((int(m.group(1), 16), m.group(2).rstrip()))
    return lines


def find_func(lines, addr):
    idx = next(i for i, (a, t) in enumerate(lines) if a == addr)
    # walk back to nearest allocframe
    start = 0
    for i in range(idx, -1, -1):
        if "allocframe" in lines[i][1]:
            start = i
            break
    else:
        start = max(0, idx - 200)
        print(f"# no allocframe found before 0x{addr:x}; using raw window", file=sys.stderr)
    # walk forward for dealloc_return
    end = min(len(lines) - 1, idx + 4000)
    for i in range(start + 1, len(lines)):
        if "dealloc_return" in lines[i][1]:
            end = i
            break
    return start, end


def main():
    path, addr = sys.argv[1], int(sys.argv[2], 0)
    lines = load(path)
    s, e = find_func(lines, addr)
    for a, t in lines[s:e + 1]:
        print(f"0x{a:08x}: {t}")


if __name__ == "__main__":
    main()
