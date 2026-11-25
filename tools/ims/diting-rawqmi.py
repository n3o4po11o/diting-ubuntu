#!/usr/bin/python3
"""Experimental: send raw QMI requests to the modem over QRTR.

    diting-rawqmi SERVICE-HEX MSGID-HEX TLVS-HEX [MSGID-HEX TLVS-HEX ...]

TLVS-HEX is "-" for none, or whole TLVs in hex with optional spaces, as
"14 03 00 69 6d 73" (type, 2 byte length, value). Instance 0 of the service.
The requests go out from one socket in order; every response is printed with
its TLVs. The service port comes from qrtr-lookup (node 0 is the modem).
"""
import ctypes
import re
import select
import socket
import struct
import subprocess
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)
AF_QIPCRTR = 42
KIND = {0: "request", 1: "response", 2: "indication"}


class Sockaddr(ctypes.Structure):
    _fields_ = [("family", ctypes.c_uint16), ("node", ctypes.c_uint32), ("port", ctypes.c_uint32)]


SIZE = ctypes.sizeof(Sockaddr)


def open_socket():
    sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    for node in range(1, 16):
        ctypes.set_errno(0)
        if libc.bind(sock.fileno(), ctypes.byref(Sockaddr(AF_QIPCRTR, node, 0)), SIZE) == 0:
            return sock
    raise OSError(ctypes.get_errno(), "bind")


def lookup(service, instance):
    """(node, port) of the modem's server for a service, from the QRTR name service"""
    listing = subprocess.run(["timeout", "3", "qrtr-lookup"], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        columns = line.split()
        if len(columns) >= 5 and columns[0].isdigit() and int(columns[0]) == service and int(columns[3]) == 0:
            if instance is None or int(columns[2]) == instance:
                return 0, int(columns[4])
    raise SystemExit("service 0x%x not found on node 0" % service)


def tlvs_of(blob):
    out, offset = [], 0
    while offset + 3 <= len(blob):
        kind, length = struct.unpack_from("<BH", blob, offset)
        out.append((kind, blob[offset + 3:offset + 3 + length]))
        offset += 3 + length
    return out


def hex_bytes(text):
    return bytes.fromhex(re.sub(r"[\s,]", "", "" if text == "-" else text))


def transact(sock, target, transaction, message, tlvs, wait=20):
    body = b"".join(tlvs)
    packet = struct.pack("<BHHH", 0, transaction, message, len(body)) + body
    libc.sendto(sock.fileno(), packet, len(packet), 0, ctypes.byref(Sockaddr(AF_QIPCRTR, *target)), SIZE)
    end = time.time() + wait
    while time.time() < end:
        if not select.select([sock], [], [], 1)[0]:
            continue
        buffer = ctypes.create_string_buffer(65536)
        source = Sockaddr()
        length = ctypes.c_uint(SIZE)
        count = libc.recvfrom(sock.fileno(), buffer, len(buffer), 0, ctypes.byref(source), ctypes.byref(length))
        if count < 7 or source.port == 0xFFFFFFFE:
            continue
        flags, seen, seen_message, size = struct.unpack_from("<BHHH", buffer.raw)
        if seen == transaction and flags & 3 != 0:
            return seen_message, tlvs_of(buffer.raw[7:7 + size]), flags
        print("  (other message: flags 0x%02x txn %d msg 0x%04x from %d:%d)" % (flags, seen, seen_message, source.node, source.port), flush=True)
    return None, [], 0


def main(arguments):
    if len(arguments) < 3 or len(arguments) % 2 != 1:
        print(__doc__, file=sys.stderr)
        return 2
    service = int(arguments[0], 16)
    rest = arguments[1:]
    sock = open_socket()
    target = lookup(service, 0)
    print("%s service 0x%x at %d:%d" % (time.strftime("%T"), service, target[0], target[1]), flush=True)
    for index in range(0, len(rest), 2):
        message = int(rest[index], 16)
        raw = hex_bytes(rest[index + 1])       # whole TLVs, taken as written
        print("%s request 0x%04x: %s" % (time.strftime("%T"), message, rest[index + 1]), flush=True)
        seen, answer, flags = transact(sock, target, index // 2 + 1, message, [raw] if raw else [])
        if seen is None:
            print("  no response", flush=True)
            break
        result = next((struct.unpack("<HH", value) for kind, value in answer if kind == 0x02), None)
        print("  response 0x%04x (flags 0x%02x): %s" % (seen, flags, "result %d error %d" % result if result else "no result TLV"), flush=True)
        for kind, value in answer:
            text = "".join(chr(c) if 32 <= c < 127 else "." for c in value[:60])
            print("    0x%02x len %3d: %-44s %s" % (kind, len(value), value[:60].hex(" "), text if len(value) > 2 else ""), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
