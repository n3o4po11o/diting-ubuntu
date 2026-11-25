#!/usr/bin/env python3
"""List what a disassembled Android vendor library does with QMI.

    qmi_calls.py DISASSEMBLY

DISASSEMBLY is llvm-objdump -d -C output of the library, with or without the
instruction bytes. Printed: every call of qmi_client_send_msg_sync with the
message id loaded into w1 before it and the function around it, and the
functions that call the other QMI entry points.
"""
import re
import sys
from collections import defaultdict

# an instruction line: "  909b4: 94003953  <tab>bl<tab><target> <symbol>"
LABEL = re.compile(r"^([0-9a-f]+) <(.+)>:$")
CALL = re.compile(r"^\s*[0-9a-f]+:\s+(?:[0-9a-f]+\s+)?bl\s+(?:0x[0-9a-f]+\s+)?<([^>]+)>")
W1 = re.compile(r"^\s*[0-9a-f]+:\s+(?:[0-9a-f]+\s+)?mov\s+w1,\s+#(0x[0-9a-f]+|\d+)")
ENTRY_POINTS = ("qmi_client_send_msg_sync", "qmi_client_send_msg_async", "qmi_client_init", "qmi_client_init_instance",
                "qmi_client_notifier_init", "qmi_client_get_any_service", "qmi_client_release",
                "qmi_csi_register", "qmi_csi_send_resp", "qmi_csi_send_ind", "qmi_csi_send_broadcast_ind",
                "qmi_csi_connect_to_client", "qmi_csi_handle_event", "qmi_client_register_error_cb",
                "qmi_client_register_notify_cb", "qmi_client_set_instance_id", "qmi_client_get_service_object")


def main(arguments):
    if len(arguments) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    function = ""
    loads = []              # recent "mov w1, #imm" in the current function
    sends = []              # (function, message id)
    callers = defaultdict(set)
    for line in open(arguments[0]):
        label = LABEL.match(line)
        if label:
            function, loads = label.group(2), []
            continue
        call = CALL.match(line)
        if not call:
            load = W1.match(line)
            if load:
                loads.append(int(load.group(1), 16) if load.group(1).startswith("0x") else int(load.group(1)))
            continue
        target = call.group(1)
        for name in ENTRY_POINTS:
            if name in target:
                callers[name].add(function)
        if "qmi_client_send_msg_sync" in target:
            sends.append((function, loads[-1] if loads else None))
    print("qmi_client_send_msg_sync: %d call sites" % len(sends))
    for function, message in sends:
        print("  0x%02x  %s" % (message if message is not None else 255, function[:160]))
    for name in ENTRY_POINTS:
        if name == "qmi_client_send_msg_sync":
            continue
        print("%s: %d functions" % (name, len(callers[name])))
        for function in sorted(callers[name])[:40]:
            print("    %s" % function[:160])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
