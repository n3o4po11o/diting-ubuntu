#!/usr/bin/python3
"""Experimental: bring up the IMS data call the way Android's telephony stack does,
and keep the WDS client that owns it until told to quit.

    diting-imscall MUX-ID [SECONDS] [COMMAND-FILE]      (run as root)

1. one WDS client: bind subscription (primary), bind mux data port (embedded, iface 1,
   the mux id given), Start Network with the parameters the Android vendor library
   uses for the IMS access point: APN "ims", IPv6, extended technology preference
   link-local (TLV 0x34 = 0x8888), call type embedded.
2. create link ims<MUX-ID> on rmnet_ipa0 for that mux id. The rmnet driver stores
   the data format per physical port and resets it on every new link, so the flags
   of the port's existing links are read and passed along, otherwise every frame
   leaves in a format the modem's IPA does not expect (it asserts).
3. bring the link up and let the kernel form its link-local address.
Then serve until the time is up or "quit" arrives; on exit the call is stopped
(by its owner, with the packet handle) and the link is deleted.

Lines in COMMAND-FILE: "status" prints the handle and address, "quit" ends.
"""
import ctypes
import os
import re
import select
import socket
import struct
import subprocess
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)
AF_QIPCRTR = 42
SERVICE_WDS = 0x01
REQUEST, RESPONSE = 0x00, 0x02
REAL_DEV = "rmnet_ipa0"
IFACE = 1
# driver flag name -> "ip link" option
FORMAT_FLAGS = {
    "INGRESS_DEAGGREGATION": "ingress-deaggregation",
    "INGRESS_MAP_COMMANDS": "ingress-commands",
    "INGRESS_MAP_CKSUMV4": "ingress-mapv4-checksum",
    "EGRESS_MAP_CKSUMV4": "egress-mapv4-checksum",
    "INGRESS_MAP_CKSUMV5": "ingress-mapv5-checksum",
    "EGRESS_MAP_CKSUMV5": "egress-mapv5-checksum",
}


class Sockaddr(ctypes.Structure):
    _fields_ = [("family", ctypes.c_uint16), ("node", ctypes.c_uint32), ("port", ctypes.c_uint32)]


SIZE = ctypes.sizeof(Sockaddr)


def stamp():
    return time.strftime("%T")


def tlv(kind, value):
    return struct.pack("<BH", kind, len(value)) + value


def tlvs_of(blob):
    out, offset = [], 0
    while offset + 3 <= len(blob):
        kind, length = struct.unpack_from("<BH", blob, offset)
        out.append((kind, blob[offset + 3:offset + 3 + length]))
        offset += 3 + length
    return out


def lookup(service):
    """(node, port) of the modem's server for a service, from the QRTR name service"""
    listing = subprocess.run(["timeout", "5", "qrtr-lookup"], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        columns = line.split()
        if len(columns) >= 5 and columns[0].isdigit() and int(columns[0]) == service and int(columns[3]) == 0:
            return 0, int(columns[4])
    raise SystemExit("service 0x%x not found on node 0" % service)


class Client:
    def __init__(self):
        self.sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for node in range(1, 16):
            ctypes.set_errno(0)
            if libc.bind(self.sock.fileno(), ctypes.byref(Sockaddr(AF_QIPCRTR, node, 0)), SIZE) == 0:
                break
        else:
            raise OSError(ctypes.get_errno(), "bind")
        self.target = lookup(SERVICE_WDS)
        self.transaction = 0

    def call(self, message, tlvs, wait=30):
        self.transaction += 1
        body = b"".join(tlvs)
        packet = struct.pack("<BHHH", REQUEST, self.transaction, message, len(body)) + body
        libc.sendto(self.sock.fileno(), packet, len(packet), 0, ctypes.byref(Sockaddr(AF_QIPCRTR, *self.target)), SIZE)
        end = time.time() + wait
        while time.time() < end:
            if not select.select([self.sock], [], [], 1)[0]:
                continue
            buffer = ctypes.create_string_buffer(65536)
            source = Sockaddr()
            length = ctypes.c_uint(SIZE)
            count = libc.recvfrom(self.sock.fileno(), buffer, len(buffer), 0, ctypes.byref(source), ctypes.byref(length))
            if count < 7 or source.port == 0xFFFFFFFE:
                continue
            flags, seen, seen_message, size = struct.unpack_from("<BHHH", buffer.raw)
            if seen == self.transaction and flags & 3 != 0:
                return tlvs_of(buffer.raw[7:7 + size])
        raise SystemExit("no response to message 0x%04x" % message)

    def result(self, message, tlvs, name):
        answer = self.call(message, tlvs)
        fields = dict(answer)
        result = struct.unpack("<HH", fields[0x02]) if 0x02 in fields else (None, None)
        print("%s %s: result %d error %d %s" % (stamp(), name, result[0], result[1],
              " ".join("0x%02x=%s" % (k, v.hex()) for k, v in answer if k != 0x02)), flush=True)
        return result, fields


def run(*words):
    return subprocess.run(words, capture_output=True, text=True)


def port_flags():
    """the data format the port's existing links were created with"""
    listing = run("ip", "-d", "-o", "link", "show", "type", "rmnet").stdout
    for line in listing.splitlines():
        if "@" + REAL_DEV + ":" in line:
            found = re.search(r"rmnet mux_id \d+ <([^>]*)>", line)
            if found:
                return [name.strip() for name in found.group(1).split(",") if name.strip()]
    raise SystemExit("no rmnet link on %s to read the data format from" % REAL_DEV)


def link_options(names):
    return [word for name, option in FORMAT_FLAGS.items()
            for word in (option, "on" if name in names else "off")]


def main(arguments):
    if len(arguments) < 1:
        print(__doc__, file=sys.stderr)
        return 2
    mux = int(arguments[0])
    seconds = int(arguments[1]) if len(arguments) > 1 else 600
    path = arguments[2] if len(arguments) > 2 else "/tmp/diting-imscall.cmd"
    link = "ims%d" % mux
    names = port_flags()
    print("%s port data format: %s" % (stamp(), " ".join(names)), flush=True)
    client = Client()
    bind = [tlv(0x10, struct.pack("<II", 4, IFACE)), tlv(0x11, bytes([mux]))]
    start = [tlv(0x14, b"ims"), tlv(0x19, bytes([6])), tlv(0x34, struct.pack("<H", 0x8888)), tlv(0x35, bytes([1]))]
    client.result(0x00AF, [tlv(0x01, struct.pack("<I", 1))], "bind subscription")
    client.result(0x00A2, bind, "bind mux data port")
    result, fields = client.result(0x0020, start, "start network")
    if result[0] != 0:
        return 1
    handle = fields[0x01]
    settings = dict(client.call(0x002D, []))          # the addresses the network gave this call
    assigned = ""
    if 0x25 in settings and len(settings[0x25]) >= 17:
        assigned = socket.inet_ntop(socket.AF_INET6, settings[0x25][:16]) + "/%d" % settings[0x25][16]
        print("%s assigned address %s" % (stamp(), assigned), flush=True)
    created = False
    try:
        command = ["ip", "link", "add", "link", REAL_DEV, "name", link, "type", "rmnet",
                   "mux_id", str(mux)] + link_options(names)
        done = run(*command)
        if done.returncode != 0:
            raise SystemExit("cannot create %s: %s" % (link, done.stderr.strip()))
        created = True
        run("nmcli", "dev", "set", link, "managed", "no")
        for command in (("ip", "link", "set", link, "addrgenmode", "none"),
                        ("ip", "link", "set", link, "up")):
            run(*command)
        # the link-local address of the call as the network assigned it, not one made up by the kernel
        run("ip", "-6", "addr", "add", assigned, "dev", link, "nodad")
        address = assigned.split("/")[0]
        if not address:
            print("%s WARNING: the call has no IPv6 address" % stamp(), flush=True)
        print("%s READY handle %s link %s address %s" % (stamp(), handle.hex(), link, address or "(none)"), flush=True)
        print("%s flags now: %s" % (stamp(), " ".join(port_flags())), flush=True)
        try:
            os.mkfifo(path)
        except FileExistsError:
            pass
        os.chmod(path, 0o666)
        commands = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        pending = b""
        end = time.time() + seconds
        while time.time() < end:
            if select.select([commands], [], [], 1)[0]:
                chunk = os.read(commands, 65536)
                if chunk:
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        words = line.decode("utf-8", "replace").split()
                        if words[:1] == ["status"]:
                            print("%s status: handle %s address %s" % (stamp(), handle.hex(), address), flush=True)
                        elif words[:1] == ["quit"]:
                            print("%s quitting on request" % stamp(), flush=True)
                            end = 0
        os.close(commands)
        os.unlink(path)
    finally:
        if created:
            run("ip", "link", "del", link)
        client.result(0x0021, [tlv(0x01, handle)], "stop network")
        print("%s port data format after cleanup: %s" % (stamp(), " ".join(port_flags())), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
