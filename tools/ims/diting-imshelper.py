#!/usr/bin/python3
"""Experimental: host the IMS data service (QMI 0x302) for the modem and bring the IMS
bearer up when the modem asks for it, as the Android daemon does; run as root.

    diting-imshelper MUX-ID [SECONDS] [COMMAND-FILE] [--reg HEX|none] [--pdp NUMBER]

Everything diting-dcm does, and on a PDP Activate Request (0x20) from the modem:
1. answer it at once: result, the pdp id, the request's sequence number and instance;
2. bring the bearer up with one WDS client: bind subscription, bind mux data port,
   Start Network with the parameters the modem accepts (APN "ims", IPv6, extended
   technology preference link-local, call type embedded), and read the address;
3. create link ims<MUX-ID> on rmnet_ipa0 with the port's data format flags (a link
   created without them makes the modem assert), bring it up, add the address;
4. send the PDP Activate indication with the pdp id, the sequence number, the address
   and the instance, then the Address Change indication.
On a PDP Deactivate Request (0x21) the call is stopped and the link is deleted.
"quit" in the command file stops the call, deletes the link and exits.
"""
import importlib.util
import os
import re
import select
import socket
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dcm", os.path.join(HERE, "diting-dcm.py"))
dcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dcm)

SERVICE_WDS = 0x01
REAL_DEV = "rmnet_ipa0"
IFACE = 1
FORMAT_FLAGS = {
    "INGRESS_DEAGGREGATION": "ingress-deaggregation",
    "INGRESS_MAP_COMMANDS": "ingress-commands",
    "INGRESS_MAP_CKSUMV4": "ingress-mapv4-checksum",
    "EGRESS_MAP_CKSUMV4": "egress-mapv4-checksum",
    "INGRESS_MAP_CKSUMV5": "ingress-mapv5-checksum",
    "EGRESS_MAP_CKSUMV5": "egress-mapv5-checksum",
}


def run(*words):
    return subprocess.run(words, capture_output=True, text=True)


def log(text):
    print("%s %s" % (time.strftime("%T"), text), flush=True)


def lookup(service):
    listing = run("timeout", "5", "qrtr-lookup").stdout
    for line in listing.splitlines():
        columns = line.split()
        if len(columns) >= 5 and columns[0].isdigit() and int(columns[0]) == service and int(columns[3]) == 0:
            return 0, int(columns[4])
    raise SystemExit("service 0x%x not found on node 0" % service)


class Client:
    def __init__(self):
        sock = socket.socket(dcm.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for node in range(1, 16):
            dcm.libc.set_errno(0)
            if dcm.libc.bind(sock.fileno(), dcm.ctypes.byref(dcm.Sockaddr(dcm.AF_QIPCRTR, node, 0)), dcm.SIZE) == 0:
                break
        else:
            raise OSError(dcm.ctypes.get_errno(), "bind")
        self.sock = sock
        self.target = lookup(SERVICE_WDS)
        self.transaction = 0

    def call(self, message, tlvs, wait=30):
        self.transaction += 1
        body = b"".join(tlvs)
        packet = struct.pack("<BHHH", dcm.REQUEST, self.transaction, message, len(body)) + body
        dcm.libc.sendto(self.sock.fileno(), packet, len(packet), 0, dcm.ctypes.byref(dcm.Sockaddr(dcm.AF_QIPCRTR, *self.target)), dcm.SIZE)
        end = time.time() + wait
        while time.time() < end:
            if not select.select([self.sock], [], [], 1)[0]:
                continue
            buffer = dcm.ctypes.create_string_buffer(65536)
            source = dcm.Sockaddr()
            length = dcm.ctypes.c_uint(dcm.SIZE)
            count = dcm.libc.recvfrom(self.sock.fileno(), buffer, len(buffer), 0, dcm.ctypes.byref(source), dcm.ctypes.byref(length))
            if count < 7 or source.port == 0xFFFFFFFE:
                continue
            flags, seen, seen_message, size = struct.unpack_from("<BHHH", buffer.raw)
            if seen == self.transaction and flags & 3 != 0:
                return dcm.tlvs_of(buffer.raw[7:7 + size])
        raise RuntimeError("no response to WDS message 0x%04x" % message)

    def result(self, message, tlvs, name):
        answer = self.call(message, tlvs)
        fields = dict(answer)
        code, error = struct.unpack("<HH", fields[0x02])
        log("%s: result %d error %d %s" % (name, code, error, " ".join("0x%02x=%s" % (k, v.hex()) for k, v in answer if k != 0x02)))
        return code, fields


def port_flags():
    listing = run("ip", "-d", "-o", "link", "show", "type", "rmnet").stdout
    for line in listing.splitlines():
        if "@" + REAL_DEV + ":" in line:
            found = re.search(r"rmnet mux_id \d+ <([^>]*)>", line)
            if found:
                return [name.strip() for name in found.group(1).split(",") if name.strip()]
    raise RuntimeError("no rmnet link on %s to read the data format from" % REAL_DEV)


def link_options(names):
    return [word for name, option in FORMAT_FLAGS.items()
            for word in (option, "on" if name in names else "off")]


class Helper(dcm.Server):
    def __init__(self, sock, reg, pdp_id, mux):
        dcm.Server.__init__(self, sock, reg, pdp_id)
        self.mux = mux
        self.link = "ims%d" % mux
        self.lock = threading.Lock()
        self.client = None
        self.handle = None
        self.address = ""

    def answer(self, source, transaction, message_id, body):
        dcm.Server.answer(self, source, transaction, message_id, body)
        if message_id == 0x20:
            fields = dict(dcm.tlvs_of(body))
            threading.Thread(target=self.bring_up, args=(fields,), daemon=True).start()
        elif message_id == 0x21:
            threading.Thread(target=self.take_down, daemon=True).start()

    def bring_up(self, fields):
        with self.lock:
            if self.client is not None:
                log("the bearer is already up (handle %s)" % self.handle.hex())
                return
            client = Client()
            names = port_flags()
            try:
                client.result(0x00AF, [dcm.tlv(0x01, struct.pack("<I", 1))], "bind subscription")
                client.result(0x00A2, [dcm.tlv(0x10, struct.pack("<II", 4, IFACE)), dcm.tlv(0x11, bytes([self.mux]))], "bind mux data port")
                code, answer = client.result(0x0020, [dcm.tlv(0x14, b"ims"), dcm.tlv(0x19, bytes([6])),
                                                       dcm.tlv(0x34, struct.pack("<H", 0x8888)), dcm.tlv(0x35, bytes([1]))], "start network")
                if code != 0:
                    client.sock.close()
                    return
                self.client = client
                self.handle = answer[0x01]
            except Exception as error:
                log("the bearer could not be started: %r" % error)
                client.sock.close()
                return
        created = False
        try:
            settings = dict(client.call(0x002D, []))
            if 0x25 in settings and len(settings[0x25]) >= 17:
                self.address = socket.inet_ntop(socket.AF_INET6, settings[0x25][:16])
            log("bearer up, handle %s, assigned address %s" % (self.handle.hex(), self.address or "(none)"))
            done = run("ip", "link", "add", "link", REAL_DEV, "name", self.link, "type", "rmnet",
                       "mux_id", str(self.mux), *link_options(names))
            if done.returncode != 0:
                raise RuntimeError("cannot create %s: %s" % (self.link, done.stderr.strip()))
            created = True
            run("nmcli", "dev", "set", self.link, "managed", "no")
            run("ip", "link", "set", self.link, "addrgenmode", "none")
            run("ip", "link", "set", self.link, "up")
            if self.address:
                run("ip", "-6", "addr", "add", self.address + "/64", "dev", self.link, "nodad")
            log("link %s up with the port's flags" % self.link)
        except Exception as error:
            log("the link could not be set up: %r" % error)
        self.notify(fields)

    def notify(self, fields=None):
        """PDP Activate indication, then Address Change indication"""
        if fields is None:
            fields = {0x10: struct.pack("<I", 0), 0x13: struct.pack("<I", 1)}
        info = dcm.address_info(1, self.address) if self.address else b""
        activate = [dcm.tlv(0x02, struct.pack("<HH", 0, 0)), dcm.tlv(0x01, bytes([self.pdp_id])), dcm.tlv(0x10, fields[0x10])]
        if info:
            activate.append(dcm.tlv(0x11, info))
        if 0x13 in fields:
            activate.append(dcm.tlv(0x12, fields[0x13]))
        self.indicate(0x20, b"".join(activate))
        if info and 0x13 in fields:
            self.indicate(0x24, b"".join([dcm.tlv(0x01, bytes([self.pdp_id])), dcm.tlv(0x10, info), dcm.tlv(0x11, fields[0x13])]))

    def take_down(self):
        with self.lock:
            client, self.client = self.client, None
        if client is None:
            return
        try:
            client.result(0x0021, [dcm.tlv(0x01, self.handle)], "stop network")
        finally:
            client.sock.close()
            run("ip", "link", "del", self.link)
            log("link %s deleted; port data format: %s" % (self.link, " ".join(port_flags())))
            self.address = ""

    def command(self, line):
        words = line.split()
        if words[:1] == ["quit"]:
            print("%s quitting on request" % time.strftime("%T"), flush=True)
            self.take_down()
            self.stopping = True
            return
        if words[:1] == ["notify"]:
            self.notify()
            return
        dcm.Server.command(self, line)


def main(arguments):
    mux = int(arguments[0])
    sys.exit(dcm.main(arguments[1:], Helper, (mux,)))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
