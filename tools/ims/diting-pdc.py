#!/usr/bin/python3
"""Experimental: talk to the carrier config service (QMI PDC, 0x24) with raw QMI.

    diting-pdc list [hw|sw]        the configurations of the modem, by their ids
    diting-pdc selected [hw|sw]    the active and the pending configuration
    diting-pdc default [hw|sw]     the configuration the modem would take for the SIM
    diting-pdc send MSGID TLVS-HEX|- [SECONDS]
                                  any request, TLVS-HEX being whole TLVs as diting-rawqmi.py
                                  takes them; every indication is printed for SECONDS

hw is the platform (hardware) configuration, sw the software one; sw is the default.
The names of the configurations need Get Config Info, whose encoding libqmi gets
right: diting-pdc-names.py. The requests that select, activate or deactivate a
configuration are not commands here; they go through "send", and what they did on
this phone is in docs/KNOWN_ISSUES.md (VoLTE).
"""
import ctypes
import select
import socket
import struct
import subprocess
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)
AF_QIPCRTR = 42
SERVICE = 0x24
TYPES = {"hw": 0, "sw": 1}


class Sockaddr(ctypes.Structure):
    _fields_ = [("family", ctypes.c_uint16), ("node", ctypes.c_uint32), ("port", ctypes.c_uint32)]


SIZE = ctypes.sizeof(Sockaddr)


def stamp():
    return time.strftime("%T")


def tlvs_of(blob):
    out, offset = [], 0
    while offset + 3 <= len(blob):
        kind, length = struct.unpack_from("<BH", blob, offset)
        out.append((kind, blob[offset + 3:offset + 3 + length]))
        offset += 3 + length
    return out


def tlv(kind, value):
    return struct.pack("<BH", kind, len(value)) + value


class Client:
    """one QRTR socket that talks to the modem's server of the service"""

    def __init__(self):
        self.sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for node in range(1, 16):          # the modem is node 0; only a local node can be bound
            ctypes.set_errno(0)
            if libc.bind(self.sock.fileno(), ctypes.byref(Sockaddr(AF_QIPCRTR, node, 0)), SIZE) == 0:
                break
        else:
            raise OSError(ctypes.get_errno(), "bind")
        self.target = None
        listing = subprocess.run(["timeout", "5", "qrtr-lookup"], capture_output=True, text=True).stdout
        for line in listing.splitlines():
            columns = line.split()
            if len(columns) >= 5 and columns[0].isdigit() and int(columns[0]) == SERVICE and int(columns[3]) == 0:
                self.target = (0, int(columns[4]))
        if not self.target:
            raise SystemExit("service 0x%x is not on node 0" % SERVICE)
        self.transaction = 0
        self.events = []                    # (message id, TLVs) of the indications received

    def receive(self, wait):
        """one packet: a response is returned, an indication is kept"""
        if not select.select([self.sock], [], [], wait)[0]:
            return None
        buffer = ctypes.create_string_buffer(65536)
        source = Sockaddr()
        length = ctypes.c_uint(SIZE)
        count = libc.recvfrom(self.sock.fileno(), buffer, len(buffer), 0, ctypes.byref(source), ctypes.byref(length))
        if count < 7 or source.port == 0xFFFFFFFE:
            return None
        flags, seen, message_id, size = struct.unpack_from("<BHHH", buffer.raw)
        body = tlvs_of(buffer.raw[7:7 + size])
        if flags & 0x04:
            self.events.append((message_id, body))
        elif flags & 0x02 and seen == self.transaction:
            return message_id, body
        return None

    def call(self, message, tlvs, wait=15):
        self.transaction += 1
        body = b"".join(tlvs)
        packet = struct.pack("<BHHH", 0, self.transaction, message, len(body)) + body
        libc.sendto(self.sock.fileno(), packet, len(packet), 0, ctypes.byref(Sockaddr(AF_QIPCRTR, *self.target)), SIZE)
        end = time.time() + wait
        while time.time() < end:
            answer = self.receive(1)
            if answer is not None:
                return answer
        raise SystemExit("no response to PDC message 0x%04x" % message)

    def ask(self, message, tlvs, seconds=3):
        """send a request, print its result, collect the indications for a few seconds"""
        del self.events[:]
        seen, answer = self.call(message, tlvs)
        result = next((struct.unpack("<HH", value) for kind, value in answer if kind == 0x02), None)
        print("%s 0x%04x: result %s error %s" % (stamp(), seen, result[0] if result else "?", result[1] if result else "?"))
        end = time.time() + seconds
        while time.time() < end:
            self.receive(max(0.1, end - time.time()))
        events, self.events[:] = self.events[:], []
        return events


def code(tlvs):
    """the indication result: a code of the service's own"""
    return next((struct.unpack("<H", value[:2])[0] for kind, value in tlvs if kind == 0x01), None)


def items(blob):
    """the configurations of a list indication: a count, then per configuration
    the type (4 bytes), a length byte and the id"""
    at = 0
    count = blob[at] if blob else 0
    at += 1
    found = []
    for _ in range(count):
        if at + 5 > len(blob):
            break
        kind = struct.unpack_from("<I", blob, at)[0]
        at += 4
        length = blob[at]
        found.append((kind, blob[at + 1:at + 1 + length]))
        at += 1 + length
    return found


def show(kind, ident):
    return "%s %s" % ("sw" if kind == 1 else "hw", ident.hex())


def ids(value):
    """an id of a get selected indication: a length byte, then the id"""
    return value[1:1 + value[0]].hex() if value and len(value) >= 1 + value[0] else value.hex()


def list_configs(client, kind):
    print("%s %s configurations in the modem:" % (stamp(), "sw" if kind else "hw"))
    # the request carries the token in TLV 0x10 and the type in TLV 0x11
    for message_id, tlvs in client.ask(0x24, [tlv(0x10, struct.pack("<I", 1)), tlv(0x11, struct.pack("<I", kind))], 4):
        if message_id == 0x24:
            for type_, value in tlvs:
                if type_ == 0x11:
                    for item_kind, ident in items(value):
                        print("  " + show(item_kind, ident))
            print("  (indication result %s)" % code(tlvs))


def selected(client, kind):
    print("%s selected %s configurations:" % (stamp(), "sw" if kind else "hw"))
    for message_id, tlvs in client.ask(0x22, [tlv(0x01, struct.pack("<I", kind)), tlv(0x10, struct.pack("<I", 1))], 4):
        if message_id == 0x22:
            for type_, value in tlvs:
                if type_ == 0x11:
                    print("  active id %s" % ids(value))
                elif type_ == 0x12:
                    print("  pending id %s" % ids(value))
            print("  (indication result %s; 16 alone means none)" % code(tlvs))


def default(client, kind):
    print("%s default %s configuration for the SIM, as the modem sees it:" % (stamp(), "sw" if kind else "hw"))
    for message_id, tlvs in client.ask(0x2A, [tlv(0x01, struct.pack("<I", kind)), tlv(0x10, struct.pack("<I", 0))], 4):
        if message_id == 0x2A:
            fields = dict(tlvs)
            version = struct.unpack("<I", fields[0x11])[0] if 0x11 in fields else None
            size = struct.unpack("<I", fields[0x12])[0] if 0x12 in fields else None
            description = fields.get(0x13, b"")
            print("  %s  version %s, %s bytes" % (
                description[1:1 + description[0]].decode("ascii", "replace") if description else "?",
                "0x%08x" % version if version is not None else "?", size))


def main(arguments):
    if arguments and arguments[0] not in ("list", "selected", "default", "send"):
        print(__doc__, file=sys.stderr)
        return 2
    command = arguments[0] if arguments else "list"
    client = Client()
    if command == "send":
        if len(arguments) < 3:
            print(__doc__, file=sys.stderr)
            return 2
        message = int(arguments[1], 16)
        raw = b"" if arguments[2] == "-" else bytes.fromhex("".join(arguments[2].split()))
        seconds = int(arguments[3]) if len(arguments) > 3 else 4
        for message_id, tlvs in client.ask(message, [raw] if raw else [], seconds):
            print("%s indication 0x%04x:" % (stamp(), message_id))
            for type_, value in tlvs:
                print("    0x%02x len %4d: %s" % (type_, len(value), value[:80].hex(" ")))
        return 0
    kind = TYPES.get(arguments[1] if len(arguments) > 1 else "sw", 1)
    client.ask(0x20, [tlv(0x10, b"\x01")], 0.5)        # reporting on, to get the indications
    {"list": list_configs, "selected": selected, "default": default}[command](client, kind)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
