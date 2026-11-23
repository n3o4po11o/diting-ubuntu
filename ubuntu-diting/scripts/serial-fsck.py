#!/usr/bin/env python3
"""Drive the diting initramfs debug shell over USB ACM:
repair the root filesystem (e2fsck -fy), then release the hold.

  serial-fsck.py /dev/cu.usbmodemXXX
"""
import re
import sys
import time

import serial

port = sys.argv[1]
ser = serial.Serial(port, timeout=1)
ser.reset_input_buffer()

log = open("/tmp/serial-fsck.log", "wb")


def read_until(pattern, timeout, what):
    rx = re.compile(pattern.encode())
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            log.write(chunk)
            log.flush()
            sys.stdout.write(chunk.decode(errors="replace"))
            sys.stdout.flush()
            m = rx.search(buf)
            if m:
                return buf
    raise SystemExit(f"\nTIMEOUT waiting for {what} ({pattern})")


def send(line):
    ser.write(line.encode() + b"\n")
    ser.flush()


# 1. handshake with the side shell (it respawns; any prompt works)
send("echo SERIAL-READY")
read_until(r"SERIAL-READY", 60, "shell handshake")

# 2. full filesystem repair; may take minutes on 10G
send("e2fsck -fy /dev/sda37; echo FSCK-RC=$?")
read_until(r"FSCK-RC=(\d+)", 1800, "e2fsck completion")

# 3. release the hold: kill the init-top script (init then continues)
send("for p in /proc/[0-9]*; do grep -q diting-debug $p/cmdline 2>/dev/null "
     "&& kill ${p#/proc/} 2>/dev/null; done; echo RESUMED")
read_until(r"RESUMED", 30, "hold release")

print("\n=== done: fs repaired, boot continues ===")
