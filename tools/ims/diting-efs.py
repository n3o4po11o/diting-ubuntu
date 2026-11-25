#!/usr/bin/python3
"""Experimental: read a file of the modem's EFS the way the Android RIL of Xiaomi phones
does: the Xiaomi extension QMI service (0xFFE4), message 0x02, command 4. Reading only.

    diting-efs [SUB] PATH [PATH ...]

Request: TLV 0x01 = 2, TLV 0x02 = the length filled, TLV 0x10 = 550 bytes of payload,
         of which the first bytes are [0] = 4 (read), [1] = the subscription, [2..3] = 0,
         [4] = the length of the path, [5..] = the path.
Answer:   the same three TLVs; TLV 0x01 is the command's result. In the payload
         [0..3] is the command echoed, [4..7] the length of the file, [8..11] the length
         of this chunk, [12..] the bytes.
A file that does not exist is not an error: its two lengths are 0.
"""
import ctypes
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pdc", os.path.join(HERE, "diting-pdc.py"))
pdc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdc)
pdc.SERVICE = 0xFFE4
SIZE = 550            # the fixed array of the message; the RIL fills 544 of it
FILLED = 544


def read(client, sub, path):
    """(result of the command, the length of the file, the bytes of its first chunk)"""
    payload = bytes([4, sub, 0, 0, len(path)]) + path.encode()
    seen, answer = client.call(0x02, [pdc.tlv(0x01, struct.pack("<I", 2)), pdc.tlv(0x02, struct.pack("<I", FILLED)),
                                      pdc.tlv(0x10, payload.ljust(SIZE, b"\0"))])
    fields = dict(answer)
    result = struct.unpack("<I", fields[0x01])[0] if len(fields.get(0x01, b"")) == 4 else None
    data = fields.get(0x10, b"")
    if len(data) < 12:
        return result, 0, b""
    total, chunk = struct.unpack_from("<II", data, 4)
    return result, total, data[12:12 + min(chunk, total)]


def main(arguments):
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 2
    sub = 0
    if arguments[0].isdigit():
        sub = int(arguments[0])
        arguments = arguments[1:]
    client = pdc.Client()
    for path in arguments:
        result, total, data = read(client, sub, path)
        if result != 0:
            print("%s: the service answers %s" % (path, result))
        elif not data:
            print("%s: no bytes (no such file, or an empty one)" % path)
        else:
            print("%s: %d bytes%s" % (path, len(data), "" if len(data) >= total else " of %d, one chunk" % total))
        for at in range(0, min(len(data), 512), 16):
            piece = data[at:at + 16]
            print("  %04x: %-48s %s" % (at, piece.hex(" "), "".join(chr(c) if 32 <= c < 127 else "." for c in piece)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
