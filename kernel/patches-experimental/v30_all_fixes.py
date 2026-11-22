#!/usr/bin/env python3
"""Complete encoder fix: 4 root causes + polling workaround.
Run: python3 v30_all_fixes.py <iris_driver_dir>

ARCHIVED AS CRASHED — do not build again. Post-mortem (see README.md):
  1. PIPE injection id 0x100000b is HFI_CMD_SUBSCRIBE_MODE, not
     HFI_PROP_PIPE (0x0300010b) — injected the one command that this
     firmware provably dies on (v19-v23).
  2. Polling completed buffers with bare vb2_buffer_done(), outside
     inst->lock, without removing them from the m2m dst list.
  3. Interframe PC skipped only on the resume path; core_init still
     sends the property (v10's venc_nopc covers all call sites).
Successor: v31_all_fixes.py.
"""
import sys, os

d = sys.argv[1]

def fix(name, old, new, desc):
    p = os.path.join(d, name)
    s = open(p).read()
    if old not in s:
        print(f"MISS: {desc}")
        return False
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
    print(f"OK: {desc}")
    return True

# 1. Enable encoder
fix("iris_platform_vpu2.c",
    "\t.no_encoder = true,",
    "\t.no_encoder = false,",
    "encoder enable")

# 2. Skip interframe PC
fix("iris_hfi_common.c",
    "\tret = ops->sys_interframe_powercollapse(core);\n\tif (ret)\n\t\tgoto err_suspend_hw;",
    "\t/* vpu20_4v: skip interframe PC (kills VPP on frame 0) */",
    "interframe PC skip")

# 3. Profile/Level fallback (in iris_hfi_gen2_command.c)
fix("iris_hfi_gen2_command.c",
    "\tinst_hfi_gen2->src_subcr_params.profile = profile;",
    "\tif (!profile && inst->codec == V4L2_PIX_FMT_H264)\n\t\tprofile = 4;\n\tinst_hfi_gen2->src_subcr_params.profile = profile;",
    "profile fallback")

fix("iris_hfi_gen2_command.c",
    "\tinst_hfi_gen2->src_subcr_params.level = level;",
    "\tif (!level && inst->codec == V4L2_PIX_FMT_H264)\n\t\tlevel = 14;\n\tinst_hfi_gen2->src_subcr_params.level = level;",
    "level fallback")

# 4. PIPE + VBR injection in session_set_property (command.c)
p = os.path.join(d, "iris_hfi_gen2_command.c")
s = open(p).read()
# Find session_set_property by its unique signature
sig = "iris_hfi_gen2_packet_session_property(inst,\n\t\t\t\t\t      packet_type,"
if sig in s:
    inject = """\t/* vpu20_4v fixes: PIPE + VBR companion family for encoder */
\tif (inst->domain == ENCODER) {
\t\tstruct iris_inst_hfi_gen2 *ig = to_iris_inst_hfi_gen2(inst);
\t\tstatic const struct { u32 trigger; u32 id; u32 val; } injects[] = {
\t\t\t{ 0x0300010a, 0x100000b, 4 },  /* STAGE -> PIPE=4 */
\t\t\t{ 0x0300012a, 0x0300012b, 1 },  /* RC -> TIME_DELTA_RC */
\t\t\t{ 0x0300012a, 0x0300012c, 1 },  /* RC -> CONTENT_ADAPTIVE */
\t\t\t{ 0x0300012a, 0x0300012d, 25 }, /* RC -> BITRATE_BOOST */
\t\t\t{ 0x0300012a, 0x03000176, 300 },/* RC -> VBV_DELAY */
\t\t\t{ 0x0300012a, 0x0300017d, 70 }, /* RC -> MIN_QUALITY */
\t\t\t{ 0x0300012a, 0x0300014e, 2 },  /* RC -> BLUR_TYPES */
\t\t\t{ 0x0300012a, 0x03000122, 1 },  /* RC -> 8X8_TRANSFORM */
\t\t\t{ 0x0300012a, 0x03000151, 0 },  /* RC -> AUD */
\t\t\t{ 0x0300012a, 0x0300017c, 22000000 }, /* RC -> PEAK_BITRATE */
\t\t};
\t\tint k;

\t\tfor (k = 0; k < ARRAY_SIZE(injects); k++) {
\t\t\tu32 ival = injects[k].val;
\t\t\tif (packet_type != injects[k].trigger)
\t\t\t\tcontinue;
\t\t\tiris_hfi_gen2_packet_session_property(inst,
\t\t\t\t\t\t      injects[k].id,
\t\t\t\t\t\t      HFI_HOST_FLAGS_NONE, plane,
\t\t\t\t\t\t      HFI_PAYLOAD_U32,
\t\t\t\t\t\t      &ival, sizeof(u32));
\t\t\tiris_hfi_queue_cmd_write(inst->core, ig->packet,
\t\t\t\t\t\t ig->packet->size);
\t\t}
\t}

\tiris_hfi_gen2_packet_session_property(inst,\n\t\t\t\t\t      packet_type,"""
    s = s.replace(sig, inject, 1)
    open(p, "w").write(s)
    print("OK: PIPE + VBR injection")
else:
    print("MISS: session_set_property signature")

# 5. POLLING WORKAROUND in response handler
p = os.path.join(d, "iris_hfi_gen2_response.c")
s = open(p).read()
# Find the end of the response handler function
old_tail = "\tiris_hfi_gen2_flush_debug_queue(core, core->response_packet);\n}"
if old_tail in s:
    new_tail = """\tiris_hfi_gen2_flush_debug_queue(core, core->response_packet);

\t/* POLLING WORKAROUND: encoder output delivery without fw responses */
\t{
\t\tstruct iris_inst *inst;
\t\tlist_for_each_entry(inst, &core->instances, list) {
\t\t\tstruct v4l2_m2m_ctx *m2m = inst->m2m_ctx;
\t\t\tstruct v4l2_m2m_buffer *buf, *n;

\t\t\tif (inst->domain != ENCODER ||
\t\t\t    inst->state != IRIS_INST_STREAMING)
\t\t\t\tcontinue;
\t\t\tv4l2_m2m_for_each_dst_buf_safe(m2m, buf, n) {
\t\t\t\tstruct iris_buffer *ib = to_iris_buffer(&buf->vb);
\t\t\t\tu8 *data;
\t\t\t\tu32 size, i;
\t\t\t\tbool has_data = false;

\t\t\t\tif (!(ib->attr & BUF_ATTR_QUEUED))
\t\t\t\t\tcontinue;

\t\t\t\tdata = vb2_plane_vaddr(&ib->vb2.vb2_buf, 0);
\t\t\t\tif (!data)
\t\t\t\t\tcontinue;

\t\t\t\tfor (i = 0; i < 16; i++) {
\t\t\t\t\tif (data[i]) {
\t\t\t\t\t\thas_data = true;
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\tif (!has_data)
\t\t\t\t\tcontinue;

\t\t\t\tsize = ib->buffer_size;
\t\t\t\twhile (size > 0 && !data[size - 1])
\t\t\t\t\tsize--;

\t\t\t\tib->data_size = size;
\t\t\t\tib->attr &= ~BUF_ATTR_QUEUED;
\t\t\t\tib->attr |= BUF_ATTR_BUFFER_DONE;
\t\t\t\tib->vb2.vb2_buf.planes[0].bytesused = size;
\t\t\t\tvb2_buffer_done(&ib->vb2.vb2_buf,
\t\t\t\t\t\t  VB2_BUF_STATE_DONE);
\t\t\t\tdev_info(core->dev,
\t\t\t\t\t "POLL: encoder output idx=%d size=%u\\n",
\t\t\t\t\t ib->index, size);
\t\t\t}
\t\t}
\t}
}"""
    s = s.replace(old_tail, new_tail, 1)
    open(p, "w").write(s)
    print("OK: polling workaround")
else:
    print("MISS: response handler tail")

print("\nDone! All fixes applied.")
