#!/usr/bin/env python3
"""v31: v10-exact encoder fixes (module params, defaults ON) + FIXED polling
workaround. Run on a CLEAN exported tree:
    python3 v31_all_fixes.py <iris_driver_dir>

Fixes over v30 (which crashed before any POLL output):
  1. PIPE injection id was 0x100000b == HFI_CMD_SUBSCRIBE_MODE (fatal to
     this fw per v19-v23); v31 uses the HFI_PROP_PIPE constant only.
  2. Polling completed buffers with bare vb2_buffer_done() outside every
     lock; v31 completes through iris_vb2_buffer_done() (the driver's own
     path: m2m removal, sequence numbers, timestamps) under inst->lock,
     with a core->lock/inst->lock dance that never nests the two.
  3. Interframe PC: v10 semantics — return 0 inside the gen2 op so BOTH
     call sites (core_init + resume path) are skipped.
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

# 2. Module params (v10 values as defaults) + interframe-PC skip at op level
fix("iris_hfi_gen2_command.c",
    """static int iris_hfi_gen2_sys_interframe_powercollapse(struct iris_core *core)
{
\tstruct iris_hfi_header *hdr;
\tint ret;

\thdr = kzalloc(SYS_IFPC_PKT_SIZE, GFP_KERNEL);""",
    """#include <linux/moduleparam.h>

/* v31: v10 module params; defaults reproduce the proven v10 session */
static int venc_profile = 4;
module_param(venc_profile, int, 0644);
static int venc_level = 14;
module_param(venc_level, int, 0644);
static int venc_pipe = 4;
module_param(venc_pipe, int, 0644);
static int venc_nopc = 1;
module_param(venc_nopc, int, 0644);

static int iris_hfi_gen2_sys_interframe_powercollapse(struct iris_core *core)
{
\tstruct iris_hfi_header *hdr;
\tint ret;

\t/* vpu20_4v: interframe PC kills VPP on frame 0 */
\tif (venc_nopc)
\t\treturn 0;

\thdr = kzalloc(SYS_IFPC_PKT_SIZE, GFP_KERNEL);""",
    "module params + nopc")

# 3. Payload overrides + VBR family + PIPE, before the main property packet
fix("iris_hfi_gen2_command.c",
    "\tiris_hfi_gen2_packet_session_property(inst,\n\t\t\t\t\t      packet_type,",
    """\t/* v31: v10 payload overrides -- also catch the streamon batch replay */
\tif (packet_type == HFI_PROP_PROFILE && venc_profile >= 0)
\t\t*(u32 *)payload = venc_profile;
\tif (packet_type == HFI_PROP_LEVEL && venc_level >= 0)
\t\t*(u32 *)payload = venc_level;

\tif (packet_type == HFI_PROP_RATE_CONTROL) {
\t\tstatic const struct {
\t\t\tu32 id;
\t\t\tu32 val;
\t\t} family[] = {
\t\t\t{ 0x0300012b, 1 },\t\t/* TIME_DELTA_BASED_RATE_CONTROL */
\t\t\t{ 0x0300012c, 1 },\t\t/* CONTENT_ADAPTIVE_CODING */
\t\t\t{ 0x0300012d, 25 },\t\t/* BITRATE_BOOST */
\t\t\t{ 0x03000176, 300 },\t\t/* VBV_DELAY (x100ms) */
\t\t\t{ 0x0300017d, 70 },\t\t/* MAINTAIN_MIN_QUALITY */
\t\t\t{ 0x0300014e, 2 },\t\t/* BLUR_TYPES (ADAPTIVE) */
\t\t\t{ 0x03000122, 1 },\t\t/* 8X8_TRANSFORM */
\t\t\t{ 0x03000151, 0 },\t\t/* AUD (disabled) */
\t\t\t{ 0x0300017c, 22000000 },\t/* TOTAL_PEAK_BITRATE */
\t\t};
\t\tu32 fval;
\t\tint k, r;

\t\tfor (k = 0; k < ARRAY_SIZE(family); k++) {
\t\t\tfval = family[k].val;
\t\t\tiris_hfi_gen2_packet_session_property(inst,
\t\t\t\t\t\t      family[k].id,
\t\t\t\t\t\t      HFI_HOST_FLAGS_NONE, plane,
\t\t\t\t\t\t      HFI_PAYLOAD_U32,
\t\t\t\t\t\t      &fval, sizeof(u32));
\t\t\tr = iris_hfi_queue_cmd_write(inst->core, inst_hfi_gen2->packet,
\t\t\t\t\t\t      inst_hfi_gen2->packet->size);
\t\t\tif (r)
\t\t\t\treturn r;
\t\t}
\t}

\tif (packet_type == HFI_PROP_STAGE && venc_pipe > 0) {
\t\tu32 pipe = venc_pipe;
\t\tint r;

\t\tiris_hfi_gen2_packet_session_property(inst,
\t\t\t\t\t\t      HFI_PROP_PIPE,
\t\t\t\t\t\t      HFI_HOST_FLAGS_NONE, plane,
\t\t\t\t\t\t      HFI_PAYLOAD_U32,
\t\t\t\t\t\t      &pipe, sizeof(u32));
\t\tr = iris_hfi_queue_cmd_write(inst->core, inst_hfi_gen2->packet,
\t\t\t\t\t\t      inst_hfi_gen2->packet->size);
\t\tif (r)
\t\t\treturn r;
\t}

\tiris_hfi_gen2_packet_session_property(inst,\n\t\t\t\t\t      packet_type,""",
    "payload overrides + VBR family + PIPE")

# 4. src_subcr_params-level profile/level (0106 second level)
fix("iris_hfi_gen2_command.c",
    "\tinst_hfi_gen2->src_subcr_params.profile = profile;",
    "\tif (venc_profile >= 0)\n\t\tprofile = venc_profile;\n\n\tinst_hfi_gen2->src_subcr_params.profile = profile;",
    "src_subcr profile")

fix("iris_hfi_gen2_command.c",
    "\tinst_hfi_gen2->src_subcr_params.level = level;",
    "\tif (venc_level >= 0)\n\t\tlevel = venc_level;\n\n\tinst_hfi_gen2->src_subcr_params.level = level;",
    "src_subcr level")

# 5. Polling workaround, fixed: driver's own completion path, no nested locks
fix("iris_hfi_gen2_response.c",
    "\tiris_hfi_gen2_flush_debug_queue(core, core->response_packet);\n}",
    """\tiris_hfi_gen2_flush_debug_queue(core, core->response_packet);

\t/* v31 POLLING WORKAROUND (vpu20_4v encoder): the fw writes encoded
\t * frames into the BITSTREAM buffers but never raises HFI_CMD_BUFFER
\t * responses; inspect the memory on every codec interrupt and complete
\t * non-empty buffers through the driver's normal dequeue path. */
\t{
\t\tstruct iris_inst *inst, *inst_tmp;

\t\tmutex_lock(&core->lock);
\t\tlist_for_each_entry_safe(inst, inst_tmp, &core->instances, list) {
\t\t\tstruct v4l2_m2m_buffer *buffer, *buf_tmp;

\t\t\tmutex_unlock(&core->lock);
\t\t\tmutex_lock(&inst->lock);

\t\t\tif (inst->domain == ENCODER &&
\t\t\t    inst->state == IRIS_INST_STREAMING) {
\t\t\t\tv4l2_m2m_for_each_dst_buf_safe(inst->m2m_ctx, buffer, buf_tmp) {
\t\t\t\t\tstruct iris_buffer *ib = to_iris_buffer(&buffer->vb);
\t\t\t\t\tu8 *data;
\t\t\t\t\tu32 size, word;
\t\t\t\t\tbool has_data = false;

\t\t\t\t\tif (!(ib->attr & BUF_ATTR_QUEUED))
\t\t\t\t\t\tcontinue;

\t\t\t\t\tdata = vb2_plane_vaddr(&ib->vb2.vb2_buf, 0);
\t\t\t\t\tif (!data)
\t\t\t\t\t\tcontinue;

\t\t\t\t\tfor (word = 0; word < 16; word++) {
\t\t\t\t\t\tif (((u32 *)data)[word]) {
\t\t\t\t\t\t\thas_data = true;
\t\t\t\t\t\t\tbreak;
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t\tif (!has_data)
\t\t\t\t\t\tcontinue;

\t\t\t\t\tsize = ib->buffer_size;
\t\t\t\t\twhile (size > 0 && !data[size - 1])
\t\t\t\t\t\tsize--;

\t\t\t\t\tib->data_size = size;
\t\t\t\t\tib->attr &= ~BUF_ATTR_QUEUED;
\t\t\t\t\tib->attr |= BUF_ATTR_BUFFER_DONE;
\t\t\t\t\tiris_vb2_buffer_done(inst, ib);
\t\t\t\t\tdev_info_ratelimited(inst->core->dev,
\t\t\t\t\t\t\t "POLL: enc output idx=%u size=%u\\n",
\t\t\t\t\t\t\t ib->index, size);
\t\t\t\t}
\t\t\t}

\t\t\tmutex_unlock(&inst->lock);
\t\t\tmutex_lock(&core->lock);
\t\t}
\t\tmutex_unlock(&core->lock);
\t}
}""",
    "polling workaround")

print("\nDone! v31 fixes applied.")
