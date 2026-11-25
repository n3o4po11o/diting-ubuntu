#!/usr/bin/python3
"""Experimental: the names of the carrier configurations of the modem through libqmi (QMI PDC).

    diting-pdc-names [hw|sw]                   every configuration of the modem, with its description
    diting-pdc-names [hw|sw] id HEX-ID [...]   only these ones (colon separators allowed)

libqmi's own encoding of Get Config Info is used: a hand-built request with a token
of 0 was refused as malformed, libqmi's is not. The ids come from diting-pdc.py, which
sits next to this file; libqmi's own list does not give them.
"""
import os
import re
import subprocess
import sys

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Qmi", "1.0")
gi.require_version("Qrtr", "1.0")
from gi.repository import GLib, Qmi, Qrtr  # noqa: E402

T = 15
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "diting-pdc.py")
loop = GLib.MainLoop()
keep = {}
state = {"ids": [], "index": 0, "token": 100, "current": None, "kind": Qmi.PdcConfigurationType.SOFTWARE}


def text(value):
    if isinstance(value, (bytes, bytearray, list)):
        return bytes(value).hex()
    return value.value_nick if hasattr(value, "value_nick") else value


def fields(output):
    """every field an indication carries"""
    out = {}
    for name in sorted(n for n in dir(type(output)) if n.startswith("get_") and n != "get_result"):
        try:
            out[name[4:]] = text(getattr(output, name)())
        except Exception:
            pass
    return out


def next_info(client):
    if state["index"] >= len(state["ids"]):
        loop.quit()
        return
    ident = list(bytes.fromhex(state["ids"][state["index"]]))
    state["current"] = state["ids"][state["index"]]
    state["index"] += 1
    message = Qmi.MessagePdcGetConfigInfoInput()
    message.set_type_with_id_v2(state["kind"], ident)
    state["token"] += 1
    message.set_token(state["token"])
    client.get_config_info(message, T, None, asked, None)


def asked(source, res, user_data=None):
    try:
        source.get_config_info_finish(res).get_result()
    except GLib.Error as error:
        print("%s: get_config_info failed: %s" % (state["current"], error.message), flush=True)
    # the indication comes before the response; the next request waits for both
    GLib.timeout_add(400, lambda: (next_info(source), GLib.SOURCE_REMOVE)[1])


def indicated(client, output):
    if state["current"] is not None:
        print("%s %s %s" % (state["current"], "sw" if state["kind"] == Qmi.PdcConfigurationType.SOFTWARE else "hw",
                            " ".join("%s=%s" % (k, v) for k, v in fields(output).items())), flush=True)


def ids_from_raw():
    """the ids of the modem's configurations of the type, from diting-pdc.py"""
    listing = subprocess.run([sys.executable, "-I", RAW, "list",
                             "hw" if state["kind"] == Qmi.PdcConfigurationType.PLATFORM else "sw"],
                             capture_output=True, text=True).stdout
    return re.findall(r"^\s+(?:sw|hw) ([0-9a-f]{40})\s*$", listing, re.M)


def registered(client, res, user_data=None):
    client.register_finish(res).get_result()
    client.connect("get-config-info", indicated)
    if state["wanted"]:
        state["ids"] = state["wanted"]
    else:
        state["ids"] = ids_from_raw()
    print("%d configurations; asking for each description" % len(state["ids"]), flush=True)
    next_info(client)


def use(client):
    keep["client"] = client
    message = Qmi.MessagePdcRegisterInput()
    message.set_enable_reporting(True)
    client.register(message, T, None, registered, None)


def allocated(source, res, user_data=None):
    use(keep["device"].allocate_client_finish(res))


def opened(source, res, user_data=None):
    keep["device"].open_finish(res)
    keep["device"].allocate_client(Qmi.Service.PDC, Qmi.CID_NONE, T, None, allocated, None)


def created(source, res, user_data=None):
    keep["device"] = Qmi.Device.new_finish(res)
    keep["device"].open(Qmi.DeviceOpenFlags.VERSION_INFO | Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, opened, None)


def bus_ready(source, res, user_data=None):
    keep["bus"] = Qrtr.Bus.new_finish(res)
    for candidate in keep["bus"].peek_nodes() or []:
        if any(info.get_service() == Qmi.Service.NAS for info in candidate.peek_service_info_list() or []):
            Qmi.Device.new_from_node(candidate, None, created, None)
            return
    raise SystemExit("no modem node")


def main(arguments):
    state["wanted"] = []
    rest = []
    while arguments:
        word, arguments = arguments[0], arguments[1:]
        if word == "hw":
            state["kind"] = Qmi.PdcConfigurationType.PLATFORM
        elif word == "sw":
            state["kind"] = Qmi.PdcConfigurationType.SOFTWARE
        elif word == "id":
            state["wanted"] = [w.replace(":", "").lower() for w in arguments]
            break
        else:
            rest.append(word)
    if rest or any(len(w) != 40 or not re.fullmatch(r"[0-9a-f]+", w) for w in state["wanted"]):
        print(__doc__, file=sys.stderr)
        return 2
    GLib.timeout_add_seconds(30 + 4 * max(1, len(state["wanted"]) or 25), loop.quit)
    Qrtr.Bus.new(1000, None, bus_ready, None)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
