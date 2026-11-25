#!/usr/bin/python3
"""Experimental: host the IMS data service (QMI 0x302) for the modem, as the Android
vendor library does (ImsQmiDcmServiceImpl), and let a script drive indications.

    diting-dcm [SECONDS] [COMMAND-FILE] [--reg HEX|none] [--pdp NUMBER]

The modem's requests are answered:
    0x23 link address          result; the modem's address and port are kept
    0x2e register app state    result, plus TLV 0x10 = the value of --reg when given.
                               The daemon of this phone sends the result alone (that
                               means "the framework brings the bearer"); an older one,
                               whose modem then asked for the bearer itself, sent 0x5f.
    0x34 service enable        result
    0x33 destroy instance      result
    0x20 pdp activate request  result, the pdp id (--pdp), the request's sequence
                               number and its instance id
    0x21 pdp deactivate req.   result, the request's pdp id and instance id
    0x22 get ip address req.   result, the address given with "addr", the instance id
    anything else              result

Lines written to COMMAND-FILE (default /tmp/diting-dcm.cmd), one per line:
    ind MSGID-HEX TLVS-HEX    send an indication to every modem client seen
    pdp NUMBER                the pdp id to answer a pdp activate request with
    reg HEX|none              what to answer to register app state in TLV 0x10
    addr IPV6|none            the address to answer a get ip address request with
    clients                   the modem clients seen
    note TEXT                 print TEXT with a time stamp
TLVS-HEX holds whole TLVs, as "01 01 00 02" (type, 2 byte length, value), spaces optional.
"""
import ctypes
import os
import re
import select
import socket
import struct
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)
AF_QIPCRTR = 42
PORT_CTRL = 0xFFFFFFFE
REQUEST, RESPONSE, INDICATION = 0x00, 0x02, 0x04
APN_TYPES = {0: "ims", 1: "internet", 2: "emergency", 3: "rcs", 4: "ut", 5: "wlan"}
RAT_TYPES = {0: "ehrpd", 1: "lte", 2: "epc", 3: "wlan"}


class Sockaddr(ctypes.Structure):
    _fields_ = [("family", ctypes.c_uint16), ("node", ctypes.c_uint32), ("port", ctypes.c_uint32)]


SIZE = ctypes.sizeof(Sockaddr)


def stamp():
    return time.strftime("%T")


def send(sock, node, port, data):
    libc.sendto(sock.fileno(), data, len(data), 0, ctypes.byref(Sockaddr(AF_QIPCRTR, node, port)), SIZE)


def host(service, version, instance):
    """publish the service; only the local node can be bound (the modem is node 0)"""
    sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    for node in range(1, 16):
        ctypes.set_errno(0)
        if libc.bind(sock.fileno(), ctypes.byref(Sockaddr(AF_QIPCRTR, node, 0)), SIZE) == 0:
            break
    else:
        raise OSError(ctypes.get_errno(), "bind")
    me = Sockaddr()
    length = ctypes.c_uint(SIZE)
    libc.getsockname(sock.fileno(), ctypes.byref(me), ctypes.byref(length))
    send(sock, me.node, PORT_CTRL, struct.pack("<IIIII", 4, service, (instance << 8) | version, me.node, me.port))
    return sock, me


def tlvs_of(blob):
    out, offset = [], 0
    while offset + 3 <= len(blob):
        kind, length = struct.unpack_from("<BH", blob, offset)
        out.append((kind, blob[offset + 3:offset + 3 + length]))
        offset += 3 + length
    return out


def hex_bytes(text):
    return bytes.fromhex(re.sub(r"[\s,]", "", text))


def tlv(kind, value):
    return struct.pack("<BH", kind, len(value)) + value


def result(code=0, error=0):
    return tlv(0x02, struct.pack("<HH", code, error))


def address_info(family, address):
    """the 48 byte structure of the indications: IP family (u32), length (u32), 40 bytes of text"""
    text = address.encode()
    return struct.pack("<II", family, len(text)) + text.ljust(40, b"\0")


def message(flags, transaction, message_id, tlvs):
    body = b"".join(tlvs)
    return struct.pack("<BHHH", flags, transaction, message_id, len(body)) + body


def u32(value, default=None):
    return struct.unpack("<I", value)[0] if len(value) == 4 else default


def describe(message_id, body):
    """the request's TLVs, with the fields that are known"""
    fields = dict(tlvs_of(body))
    text = " ".join("0x%02x=%s" % (kind, value.hex()) for kind, value in tlvs_of(body))
    if message_id == 0x23 and 0x01 in fields:
        value = fields[0x01]
        if len(value) >= 7:
            text += "  port %d, %d %s %r" % (struct.unpack_from("<H", value)[0], u32(value[2:6]),
                                               value[6:7].hex(), bytes(value[7:]))
    elif message_id == 0x20 and 0x01 in fields:
        # the connection parameters: the access point name, then the type, the radio, the
        # IP family and the profile number; where they sit depends on the modem's version
        value = fields[0x01]
        name = value[1:1 + value[0]] if value and value[0] < len(value) else b""
        words = [u32(value[i:i + 4]) for i in range(len(value) - 16, len(value) - 3, 4)] if len(value) >= 16 else []
        text += "  apn %r %s" % (name, " ".join(str(w) for w in words))
        for label, kind in (("seq", 0x10), ("subscription", 0x11), ("slot", 0x12), ("instance", 0x13)):
            if kind in fields:
                text += " %s %s" % (label, u32(fields[kind], fields[kind].hex()))
    return text


class Server:
    def __init__(self, sock, reg, pdp_id):
        self.sock = sock
        self.clients = []           # modem client (node, port) addresses, most recent last
        self.reg = reg              # none, or the value for TLV 0x10 of the register app state answer
        self.pdp_id = pdp_id
        self.address = ""

    def answer(self, source, transaction, message_id, body):
        fields = dict(tlvs_of(body))
        print("%s request 0x%04x from %d:%d txn %d  %s" % (
            stamp(), message_id, source.node, source.port, transaction, describe(message_id, body)), flush=True)
        tlvs = [result()]
        if message_id == 0x2e and self.reg is not None:
            tlvs.append(tlv(0x10, struct.pack("<I", self.reg)))
        elif message_id == 0x20:
            tlvs.append(tlv(0x10, bytes([self.pdp_id])))
            if 0x10 in fields:
                tlvs.append(tlv(0x11, fields[0x10]))          # the sequence number
            if 0x13 in fields:
                tlvs.append(tlv(0x12, fields[0x13]))          # the instance id
        elif message_id == 0x21:
            if 0x01 in fields:
                tlvs.append(tlv(0x10, fields[0x01]))
            if 0x10 in fields:
                tlvs.append(tlv(0x11, fields[0x10]))
        elif message_id == 0x22 and self.address:
            tlvs.append(tlv(0x10, address_info(1, self.address)))
            if 0x10 in fields:
                tlvs.append(tlv(0x11, fields[0x10]))
        send(self.sock, source.node, source.port, message(RESPONSE, transaction, message_id, tlvs))

    def indicate(self, message_id, raw):
        for node, port in list(self.clients):
            send(self.sock, node, port, message(INDICATION, 0, message_id, [raw] if raw else []))
        print("%s indication 0x%04x %s to %s" % (stamp(), message_id, raw.hex(" ") if raw else "(no TLVs)", self.clients), flush=True)

    def command(self, line):
        words = line.split()
        if not words:
            return
        try:
            if words[0] == "ind" and len(words) >= 2:
                # the TLVs may be written with or without spaces between the bytes
                self.indicate(int(words[1], 16), hex_bytes("".join(words[2:])) if len(words) > 2 else b"")
            elif words[0] == "pdp" and len(words) > 1:
                self.pdp_id = int(words[1], 0)
                print("%s pdp id %d" % (stamp(), self.pdp_id), flush=True)
            elif words[0] == "reg" and len(words) > 1:
                self.reg = None if words[1] == "none" else int(words[1], 0)
                print("%s register app state answer: TLV 0x10 = %s" % (stamp(), self.reg), flush=True)
            elif words[0] == "addr" and len(words) > 1:
                self.address = "" if words[1] == "none" else words[1]
                print("%s get ip address answer: %s" % (stamp(), self.address or "(none)"), flush=True)
            elif words[0] == "clients":
                print("%s clients %s" % (stamp(), self.clients), flush=True)
            elif words[0] == "note":
                print("%s note %s" % (stamp(), " ".join(words[1:])), flush=True)
            else:
                print("%s unknown command: %s" % (stamp(), line), flush=True)
        except ValueError as error:
            print("%s cannot read the command (%s): %s" % (stamp(), error, line), flush=True)


def main(arguments, server_class=None, extra=()):
    """serve for the seconds given; server_class replaces Server (see diting-imshelper.py)"""
    options = {"--reg": None, "--pdp": None}
    positional = []
    index = 0
    while index < len(arguments):
        if arguments[index] in options:
            options[arguments[index]] = arguments[index + 1]
            index += 2
        else:
            positional.append(arguments[index])
            index += 1
    seconds = int(positional[0]) if positional else 300
    path = positional[1] if len(positional) > 1 else "/tmp/diting-dcm.cmd"
    reg = None
    if options["--reg"] not in (None, "none"):
        reg = int(options["--reg"], 0)
    sock, me = host(0x302, 1, 0)
    print("%s hosting service 0x302 version 1 instance 0 at %d:%d for %d s; register app state answer TLV 0x10 = %s; "
          "commands in %s" % (stamp(), me.node, me.port, seconds, reg, path), flush=True)
    server = (server_class or Server)(sock, reg, int(options["--pdp"], 0) if options["--pdp"] else 20, *extra)
    try:
        os.mkfifo(path)
    except FileExistsError:
        pass
    os.chmod(path, 0o666)
    commands = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    pending = b""
    end = time.time() + seconds
    try:
        serve(sock, server, commands, end, me)
    finally:
        os.close(commands)
        os.unlink(path)
    print("%s done" % stamp(), flush=True)
    return 0


def serve(sock, server, commands, end, me):
    pending = b""
    while time.time() < end and not getattr(server, "stopping", False):
        ready = select.select([sock, commands], [], [], 1)[0]
        if commands in ready:
            try:
                chunk = os.read(commands, 65536)
            except BlockingIOError:   # the reader is woken without data
                chunk = None
            if chunk:                     # an empty read: the writer closed the pipe
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    server.command(line.decode("utf-8", "replace").strip())
        if sock not in ready:
            continue
        buffer = ctypes.create_string_buffer(65536)
        source = Sockaddr()
        length = ctypes.c_uint(SIZE)
        count = libc.recvfrom(sock.fileno(), buffer, len(buffer), 0, ctypes.byref(source), ctypes.byref(length))
        if count < 7 or source.port == PORT_CTRL or source.node == me.node:
            continue
        flags, transaction, message_id, size = struct.unpack_from("<BHHH", buffer.raw)
        if flags & 3 != REQUEST:
            continue
        if (source.node, source.port) not in server.clients:
            server.clients.append((source.node, source.port))
        server.answer(source, transaction, message_id, buffer.raw[7:7 + size])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
