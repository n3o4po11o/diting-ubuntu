#!/usr/bin/env python3
"""EXPERIMENT (never committed): firmware log + HFI TX/RX tracing.

Applies on top of the clean patch series. Usage:
    python3 exp-fwlog-trace.py <iris_driver_dir | kernel_src_dir>
(exp-build.sh passes the kernel source root, like for every other script)

- adds iris_hfi_gen2_packet_sys_debug_config() and sends it after sys_init
  when the module parameter fwlog_level is non-zero (default 0x2b)
- dev_dbg() trace of every HFI packet written / received
Enable with:  echo module qcom_iris +p > /sys/kernel/debug/dynamic_debug/control
"""
import sys, os

d = sys.argv[1]
if not os.path.exists(os.path.join(d, "iris_hfi_gen2_packet.c")):
    d = os.path.join(d, "drivers/media/platform/qcom/iris")


def edit(name, old, new, tag):
    p = os.path.join(d, name)
    old = old.replace("${T}", "\t")
    new = new.replace("${T}", "\t")
    s = open(p).read()
    if new in s:
        print("SKIP (already applied):", tag)
        return
    assert s.count(old) == 1, "MISS %s (%d)" % (tag, s.count(old))
    open(p, "w").write(s.replace(old, new, 1))
    print("OK:", tag)


NL = "\n"
T = "\t"

# ---- packet.c: public builder for the debug config packet ----------------
edit("iris_hfi_gen2_packet.c",
     "void iris_hfi_gen2_packet_sys_pc_prep(struct iris_core *core, struct iris_hfi_header *hdr)\n{",
     "void iris_hfi_gen2_packet_sys_debug_config(struct iris_core *core, struct iris_hfi_header *hdr,\n"
     "${T}${T}${T}${T}${T}${T}${T} ${T}u32 cfg, u32 level)\n"
     "{\n"
     "${T}iris_hfi_gen2_create_header(hdr, 0 /*session_id*/, core->header_id++);\n\n"
     "${T}iris_hfi_gen2_create_packet(hdr,\n"
     "${T}${T}${T}${T}${T}${T}${T}    0x0300000a,	/* HFI_PROP_DEBUG_CONFIG */\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_HOST_FLAGS_NONE,\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_PAYLOAD_U32_ENUM,\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_PORT_NONE,\n"
     "${T}${T}${T}${T}${T}${T}${T}    core->packet_id++,\n"
     "${T}${T}${T}${T}${T}${T}${T}    &cfg,\n"
     "${T}${T}${T}${T}${T}${T}${T}    sizeof(u32));\n"
     "${T}iris_hfi_gen2_create_packet(hdr,\n"
     "${T}${T}${T}${T}${T}${T}${T}    0x0300000b,	/* HFI_PROP_DEBUG_LOG_LEVEL */\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_HOST_FLAGS_NONE,\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_PAYLOAD_U32_ENUM,\n"
     "${T}${T}${T}${T}${T}${T}${T}    HFI_PORT_NONE,\n"
     "${T}${T}${T}${T}${T}${T}${T}    core->packet_id++,\n"
     "${T}${T}${T}${T}${T}${T}${T}    &level,\n"
     "${T}${T}${T}${T}${T}${T}${T}    sizeof(u32));\n"
     "}\n\n"
     "void iris_hfi_gen2_packet_sys_pc_prep(struct iris_core *core, struct iris_hfi_header *hdr)\n{",
     "packet.c debug config builder")

edit("iris_hfi_gen2_packet.h",
     "void iris_hfi_gen2_packet_sys_pc_prep(struct iris_core *core, struct iris_hfi_header *hdr);",
     "void iris_hfi_gen2_packet_sys_debug_config(struct iris_core *core, struct iris_hfi_header *hdr,\n"
     "${T}${T}${T}${T}${T}${T}${T} ${T} ${T}u32 cfg, u32 level);\n"
     "void iris_hfi_gen2_packet_sys_pc_prep(struct iris_core *core, struct iris_hfi_header *hdr);",
     "packet.h declaration")

# ---- command.c: module parameter + send after sys_init -------------------
edit("iris_hfi_gen2_command.c",
     "#include \"iris_hfi_gen2.h\"\n#include \"iris_hfi_gen2_packet.h\"\n",
     "#include \"iris_hfi_gen2.h\"\n#include \"iris_hfi_gen2_packet.h\"\n"
     "#include <linux/moduleparam.h>\n\n"
     "/* EXPERIMENT: firmware debug log level, 0 = off */\n"
     "static unsigned int fwlog_level = 0x2b;\n"
     "module_param(fwlog_level, uint, 0644);\n",
     "command.c module param")

edit("iris_hfi_gen2_command.c",
     "${T}iris_hfi_gen2_packet_sys_init(core, hdr);\n"
     "${T}ret = iris_hfi_queue_cmd_write_locked(core, hdr, hdr->size);\n\n"
     "${T}kfree(hdr);\n\n"
     "${T}return ret;\n}",
     "${T}iris_hfi_gen2_packet_sys_init(core, hdr);\n"
     "${T}ret = iris_hfi_queue_cmd_write_locked(core, hdr, hdr->size);\n\n"
     "${T}kfree(hdr);\n\n"
     "${T}if (!ret && fwlog_level) {\n"
     "${T}${T}/* EXPERIMENT: ask the firmware for its own log */\n"
     "${T}${T}hdr = kzalloc(SYS_INIT_PKT_SIZE, GFP_KERNEL);\n"
     "${T}${T}if (!hdr)\n"
     "${T}${T}${T}return -ENOMEM;\n\n"
     "${T}${T}iris_hfi_gen2_packet_sys_debug_config(core, hdr,\n"
     "${T}${T}${T}${T}${T}${T}${T}${T}${T}${T}${T} ${T}      1,	/* HFI_DEBUG_CONFIG_CLRDBGQ */\n"
     "${T}${T}${T}${T}${T}${T}${T}${T}${T}${T}${T} ${T}      fwlog_level);\n"
     "${T}${T}ret = iris_hfi_queue_cmd_write_locked(core, hdr, hdr->size);\n"
     "${T}${T}kfree(hdr);\n"
     "${T}}\n\n"
     "${T}return ret;\n}",
     "command.c send debug config")

# ---- queue.c: TX trace ----------------------------------------------------
edit("iris_hfi_queue.c",
     "#include \"iris_core.h\"\n#include \"iris_hfi_queue.h\"\n",
     "#include \"iris_core.h\"\n#include \"iris_hfi_gen2_packet.h\"\n#include \"iris_hfi_queue.h\"\n",
     "queue.c include")

edit("iris_hfi_queue.c",
     "${T}struct iris_iface_q_info *q_info = &core->command_queue;\n",
     "${T}struct iris_iface_q_info *q_info = &core->command_queue;\n"
     "${T}struct iris_hfi_header *thdr = pkt;\n"
     "${T}u32 toff = sizeof(*thdr);\n"
     "${T}unsigned int ti;\n\n"
     "${T}dev_dbg(core->dev, \"hfi tx: sid %u hdr %#x npkt %u\\n\",\n"
     "${T}${T}thdr->session_id, thdr->header_id, thdr->num_packets);\n"
     "${T}for (ti = 0; ti < thdr->num_packets && ti < 32 && toff < thdr->size; ti++) {\n"
     "${T}${T}struct iris_hfi_packet *tp = (void *)thdr + toff;\n\n"
     "${T}${T}dev_dbg(core->dev, \"hfi tx pkt[%u]: %#x p0 %x p1 %x\\n\", ti,\n"
     "${T}${T}${T}tp->type, tp->payload[0], tp->payload[1]);\n"
     "${T}${T}toff += tp->size;\n"
     "${T}}\n",
     "queue.c tx trace")

# ---- response.c: RX trace ------------------------------------------------
edit("iris_hfi_gen2_response.c",
     "static int iris_hfi_gen2_handle_response(struct iris_core *core, void *response)\n{\n"
     "${T}struct iris_hfi_header *hdr = (struct iris_hfi_header *)response;\n"
     "${T}int ret;\n",
     "static int iris_hfi_gen2_handle_response(struct iris_core *core, void *response)\n{\n"
     "${T}struct iris_hfi_header *hdr = (struct iris_hfi_header *)response;\n"
     "${T}u32 roff = sizeof(*hdr);\n"
     "${T}unsigned int ri;\n"
     "${T}int ret;\n\n"
     "${T}dev_dbg(core->dev, \"hfi rx: sid %u hdr %#x npkt %u\\n\",\n"
     "${T}${T}hdr->session_id, hdr->header_id, hdr->num_packets);\n"
     "${T}for (ri = 0; ri < hdr->num_packets && ri < 32 && roff < hdr->size; ri++) {\n"
     "${T}${T}struct iris_hfi_packet *rp = (void *)hdr + roff;\n\n"
     "${T}${T}dev_dbg(core->dev, \"hfi rx pkt[%u]: %#x flags %x p0 %x p1 %x\\n\", ri,\n"
     "${T}${T}${T}rp->type, rp->flags, rp->payload[0], rp->payload[1]);\n"
     "${T}${T}roff += rp->size;\n"
     "${T}}\n",
     "response.c rx trace")

print("experiment applied")
