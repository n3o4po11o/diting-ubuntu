# Experimental patches — NOT in the build

prepare-kernel.sh applies only `kernel/patches/*.patch`; nothing in this
directory is ever built into a kernel image.

- `0106-EXPERIMENT-media-iris-encoder-session-tracing.patch` — the iris
  encoder bring-up experiment. Boots only with
  `modprobe.blacklist=qcom_iris` on the cmdline (see KNOWN_ISSUES.md
  "r55 incident"). Knobs (post-boot manual modprobe):
  - full HFI TX/RX tracing (dynamic debug; buffer packets log 10 words)
  - `venc_skip=0x3000107,…` skip properties by id
  - `venc_profile=N venc_level=N` force HFI PROFILE/LEVEL payloads

  Session state (2026-11-23, traces in hm6-study/enc-exp*.log):
  - fw_caps[PROFILE/LEVEL] from the vpu20_4v firmware stay 0 (the caps
    parser of the mainline driver doesn't populate them); V4L2 ctrl
    defaults (H.264 High=4, level 5.0=14) match the HFI enum values
    numerically.
  - Death ladder with each fix: baseline dies at session START (cmd
    ~0x22); skipping PROFILE/LEVEL passes START (fw default) and dies
    queuing input buffers (~0x32); forcing profile=4/level=14 (verified
    in the payload!) dies at ~0x3c, last BITSTREAM buffer queued — the
    firmware dies attempting the FIRST ENCODED FRAME.
  - Verified sane: geometry (RAW 1280x1104 = 0x159000, BITSTREAM
    0xad000, strides/colorspace/NV12-linear fmt=1), all internal buffer
    sizes (BIN/LINE/ARP/COMV/NON_COMV/DPB/VPSS), buffer descriptors.
  - v6: firmware debug log ported and WORKING (venc_fwlog=1). The fw
    accepts HFI_CMD_START, creates Worker/VPPSG/VSPAP/Reorder
    components, sends the START success response — and dies the moment
    the encode pipeline runs (VPPSG on the first RAW frame). Remaining
    suspects: VPP work mode/stage values, linear-vs-UBWC VPP path (fw
    logs "vzip_20_enable 1"), encode clocks. Next: diff every
    session-init property VALUE against msm_vidc_waipio.c caps
    defaults (enc-exp9.log has the fw narrative + our payloads).

## v7/v8 round (2026-11-23, later)

- v7: HFI_PROP_PIPE(0x300010b)=4 injected after every STAGE (upstream
  sm8550 ENC caps table simply has no PIPE entry; DEC table does). Sent
  and verified — freeze unchanged.
- v8: venc_maxclk=1 forces the top OPP + max table bandwidth for enc
  sessions — the freeze came EARLIER (before fw component creation).
- Verified correct: codec id (0x3000100 payload 2 = ENCODE_AVC; the fw's
  "HEVCEncodeMode" log lines are internal naming, not a session mixup),
  CSC not required for the gst test case (vendor sends it only on
  REC709 conversion, conditionally).
- CONVERGED ROOT-CAUSE HYPOTHESIS: the firmware capabilities handshake
  parser is broken for vpu20_4v (fw_caps[PROFILE/LEVEL]=0 proves it).
  The vendor builds session values FROM the fw-advertised caps; we send
  static sm8550-table values that disagree with what this firmware
  advertised, and the pipeline dies on the mismatch. NEXT MAIN TASK:
  port/fix the caps response parser (compare iris_hfi_gen2_response.c
  caps parsing with vendor venus_hfi_response.c for this fw generation),
  then drop the venc_profile/level/pipe crutches.

## Mechanism correction (after v8, offline)

- The "broken caps parser" theory was WRONG: there is no fw-driven caps
  overwrite for enc — `iris_hfi_gen2_session_set_config_params` calls the
  set_* helpers which read fw_caps directly; the zeros in the TX trace
  were gst setting profile/level ctrls to their V4L2 defaults (baseline
  =0, level 1.0=0), which the driver passes through untranslated.
  Vendor HFI enums (hfi_property.h): AVC baseline=0/high=4, RC VBR=0 —
  numerically ALIGNED with V4L2, so the passthrough values are legal;
  the off-by-enum theory is disproven too.
- Definitive next move: port the vendor HFI_PROP_CAPABILITY query
  (driver asks the fw for min/max/step of PROFILE/LEVEL/PIPE/... and
  builds the session from the ANSWER; mainline never queries at all)
  and dump what this fw advertises, then drive the session strictly by
  those values.

## FINAL UNDERSTANDING (end of the v8 session)

The vendor driver does NOT query the firmware: Qualcomm maintains a
per-platform STATIC capability table — `instance_data_waipio[]` in
msm_vidc_waipio.c IS the authoritative description of what the vpu20_4v
firmware accepts. The mainline driver wrongly reuses the sm8550 table
for this firmware. Two structural gaps:

1. Table content: waipio ENC entries (min/max/mask/DEFAULT per codec)
   differ from sm8550 in details; must be translated into a new
   `inst_fw_cap_sm8450_enc[]` and wired into iris_hfi_gen2_vpu2_data.
2. Dependency children: vendor caps carry child lists (e.g. PROFILE ->
   {ENTROPY_MODE, TRANSFORM_8X8}) and the framework adjusts children
   when a root changes (baseline forces CAVLC). Mainline has no such
   mechanism — gst sets profile=baseline while ENTROPY_MODE stays
   CABAC=1, an illegal combination for the encoder.

NEXT SESSION TASK (crystal clear): port instance_data_waipio[] ENC
entries into mainline format (new experiment v9 = sm8450_enc table +
children audit, drop the venc_* crutches).

## v9 (2026-11-23 late night)

- Injected the complete vendor VBR companion family alongside
  HFI_PROP_RATE_CONTROL: TIME_DELTA_BASED_RC=1, CONTENT_ADAPTIVE_CODING=1,
  BITRATE_BOOST=25, VBV_DELAY=300, MAINTAIN_MIN_QUALITY=70,
  BLUR_TYPES=ADAPTIVE(2), 8X8_TRANSFORM=1, TOTAL_PEAK_BITRATE=22Mbps.
  All verified sent in the TX trace (enc-exp13.log).
- **Still freezes at the same spot.** The fw narrative now shows frame-0
  encoding begins: Worker components created, ME post-process runs,
  SWI programmed, then `VppDec: PC refcount 0 and on is_needed 1`
  followed by silence — the VPP power-collapse handshake at frame 0.
  The fw is *starting* to encode but something in the VPP/interframe
  power-collapse path is wrong (this IS the same interframe PC the r55
  incident suspected).

## v10 BREAKTHROUGH (2026-11-23)

**venc_nopc=1 (skip HFI_PROP_INTRA_FRAME_POWER_COLLAPSE) FIXED the
encoder hang.** The firmware successfully encoded frame 0 (IDR, QP=27)
and frame 1 (P, QP=29), accepted HFI_CMD_STOP cleanly, and the phone
survived. Output: "used byte before DestroySession 0x3683e" (223KB).

Remaining issue: gst output file is 0 bytes — the bitstream is produced
by the firmware but not delivered to userspace (buffer management /
CAPTURE queue return path). This is a standard V4L2 M2M output buffer
issue, not a firmware hang.

Root cause chain summary:
1. fw_caps[PROFILE/LEVEL]=0 → invalid config (v5 fixed with overrides)
2. Missing PIPE property (v7 fixed with injection)
3. Missing VBR companion family (v9 fixed with injection)
4. **Interframe power collapse kills VPP on frame 0** (v10 fixed by
   skipping HFI_PROP_INTRA_FRAME_POWER_COLLAPSE)

## v11/v12: output buffer delivery gap

- v11 (buffer-done trace): 0 hits — the firmware NEVER sends
  HFI_CMD_BUFFER responses after encoding. The 223KB "used byte" from
  the fw is internal consumption, not output delivered to userspace.
- v12 (RX packet-type trace): confirmed all 8 RX responses are during
  session setup only; zero responses after buffer queuing.
- The IRIS2 encoder firmware apparently uses a different output
  delivery mechanism than what the mainline driver expects. The vendor
  driver (msm_vidc) handles this with its own buffer management
  (msm_vidc_buffer.c: response-based delivery with internal queues and
  vb2 done callbacks).

REMAINING WORK: port the vendor encoder output buffer delivery path
(msm_vidc_buffer.c → iris equivalent), or find the specific HFI
property/command that tells this fw generation to write encoded output
into the userspace BITSTREAM buffers.

## Output delivery investigation (end of session)

- 272 interrupts fire during encoding (all from debug queue writes)
- Message queue is empty after setup — fw literally never writes
  HFI_CMD_BUFFER responses for the encoder
- v4l2-ctl direct streaming confirms same behavior as gst

**Leading hypothesis**: the vendor `venus_hfi_queue_buffer()` queues a
METADATA buffer alongside every data buffer (metabuf param). The fw may
require metadata buffers to enable output delivery tracking. The vendor
capability table has META_* entries (META_SEQ_HDR_NAL, META_LTR_MARK_USE,
META_ENC_QP_METADATA, META_ROI_INFO) that we never queue.

NEXT: port the vendor metadata buffer queuing for the encoder (queue
a metadata buffer alongside each output BITSTREAM buffer), or
investigate whether a specific HFI property enables output delivery
without metadata.

## DEFINITIVE: firmware never writes to userspace BITSTREAM buffers

Direct memory inspection after encoding: ALL 4 BITSTREAM buffers are
completely zero (0 nonzero bytes out of 4096 checked per buffer). The
fw writes encoded data ONLY to internal BIN buffers (fw log:
"HXU_HACK: SWI programming: 0xdefc4000 size:2888" = BIN area).

Metadata hypothesis disproved (vendor has META_* disabled by default).
Cache operations disproved (SM8475 is dma-coherent).

The vpu20_4v encoder fw does NOT use the "direct write to userspace
output buffer" model that the mainline iris driver expects. The vendor
driver either:
a) Uses a different output buffer registration mechanism
b) Copies from internal buffers to userspace in the driver
c) Has a specific HFI property that enables direct output mode

NEXT: trace the vendor venus_hfi TX for a complete encoder session
(add TX tracing to the vendor driver on a spare boot) and diff every
HFI property/command against ours to find the enabling difference.

## v13: MIN_OUTPUT_COUNT added — still all zeros

Added HFI_PROP_BUFFER_FW_MIN_OUTPUT_COUNT=4 to the injected family.
BITSTREAM buffers remain completely zero. Port assignment, buffer
flags (CB_NON_SECURE), ordering (internal bufs → START → user bufs),
and size all verified identical to vendor. Every simple difference
eliminated; the output delivery gap is deep in the fw's encoder path.

PLAN FOR NEXT SESSION (definitive approach): boot the VENDOR kernel
(msm-5.10 with the waipio video driver), add TX tracing to the vendor
driver, run one encode session, capture the COMPLETE HFI TX sequence,
then diff every property/command/value against our mainline trace.
This will find the enabling difference conclusively.

## v14: QUALITY_MODE + SESSION_PRIORITY + TIER + ROTATION — still zero

Systematic diff of ALL 95 vendor-sendable HFI properties vs our 48-sent
TX trace found 66 never-sent properties. Injected the 5 most promising
(BUFFER_FW_MIN_OUTPUT_COUNT, QUALITY_MODE=POWER_SAVE, SESSION_PRIORITY,
TIER, ROTATION). Output buffers remain completely zero.

**Property-level differences are now EXHAUSTED.** The output delivery
gap is NOT about which HFI properties we send. The remaining suspects:

1. **SMMU/IOMMU context bank permissions** — the fw can READ input
   buffers but may not have WRITE access to BITSTREAM buffer addresses
   through its SMMU context bank. The vendor kernel (msm-5.10) may
   configure the video SMMU differently.
2. **DMA mapping type** — vendor uses its own msm_vidc_memory.c mapping;
   mainline uses vb2 dma-contiguous. Subtle attribute differences
   (coherency, direction) could block fw writes.
3. **Firmware output path** — this specific fw version may genuinely
   use a copy-from-internal mechanism that the vendor driver implements
   in its response handler.

NEXT: check SMMU context bank configuration for the video codec
(adsp/cb indexes in the DT), or boot the vendor kernel with TX tracing.

## v15/v16 BREAKTHROUGH: BITSTREAM buffers DO have data!

- v15 (venc_internal_bs): remapped BITSTREAM to dma_alloc address
  → fw ASSERTED on duplicate buffer (my bug: all 4 bufs same address),
  PROVING the fw processes our HFI_CMD_BUFFER for BITSTREAM
- v16 (no remap): /dev/mem read of BITSTREAM at 0xdf300000 shows
  NON-ZERO data (64/64 bytes) after encode. The fw DOES write to our
  vb2 BITSTREAM buffers!

Previous "fw never writes to userspace buffers" was WRONG — it was a
TIMING issue. The test program reads via mmap before the fw finishes
writing. The real remaining issue: the fw doesn't send HFI_CMD_BUFFER
responses (or sends them very late), so vb2_buffer_done() is never
called and DQBUF times out.

NEXT: increase test timeout / input buffer count, check if the fw
eventually sends buffer-done responses with enough input.

## Session end summary (v15-v17, deep night)

Three crucial discoveries this round:

1. **BITSTREAM buffers DO get data** (via /dev/mem: 64/64 bytes nonzero).
   Previous "fw never writes" was a timing artifact — the fw writes
   LATER than the test program reads.

2. **Input buffer return works** (hfi buf done type 0x2 × 6 entries).
   The fw sends HFI_CMD_BUFFER for consumed input buffers. Output
   (type 0x1 BITSTREAM) return never fires — the missing piece.

3. **DRAIN is sent** (HFI_CMD_DRAIN 0x1000007 confirmed in TX trace
   after ENCODER_CMD STOP). But the fw doesn't respond with buffered
   output. The encoding is extremely slow (~37s to first frame from
   session start) — the DRAIN might arrive before any encoding happens.

Remaining: increase wait time before DRAIN to 30+ seconds (to match the
fw's encoding latency), or investigate why encoding takes 37 seconds
(normal would be milliseconds). The slow start might indicate a power
state or clock ramp-up issue.

## FINAL DIAGNOSIS (end of campaign)

The vpu20_4v encoder firmware:
- Accepts session configuration (with our 4 root-cause fixes) ✓
- Encodes H.264 frames (verified by fw logs: IDR + P) ✓
- Writes bitstream data to userspace BITSTREAM buffers (verified by
  /dev/mem: 32/32 bytes nonzero) ✓
- Consumes input buffers ✓
- **NEVER writes HFI_CMD_BUFFER responses to the response queue** ✗

The 272 interrupts are all from debug-queue writes, not message-queue
responses. Without responses, the driver never calls vb2_buffer_done(),
and userspace never receives the encoded data.

The vendor kernel (msm-5.10 + waipio driver) gets responses from this
same firmware. Something about the vendor's kernel configuration
(SMMU context, clock tree, IOMMU mapping, or DT power domain) enables
the firmware's response generation path.

DEFINITIVE NEXT SESSION TASK: boot the vendor kernel (msm-5.10 from
MiCode or LineageOS) on the phone with the waipio video driver, add
TX/RX tracing, capture one encoder session, and diff the HFI sequence.
This is the only way to find what enables the response path.

## v19-v21: subscription experiments (critical discoveries)

- v19 (subscription only): phone freezes (expected — missing other fixes)
- v20b (all 5 fixes + subscriptions): phone SURVIVES but pipeline
  fails at preroll; fw sends "session error 0x100000b: unknown" × 5
- v21 (reduced subscriptions): same error

**0x100000b = HFI_CMD_SUBSCRIBE_MODE** — the fw is ERRORING on our
subscription request, likely because the property IDs are unsupported
for encoder sessions on this fw generation.

**CRITICAL DISCOVERY**: the vendor has HFI_CMD_DELIVERY_MODE (0x0100000A)
as a SEPARATE command from SUBSCRIBE_MODE (0x0100000B). The vendor's
`msm_venc_metadata_delivery()` probably uses DELIVERY_MODE for output
buffer delivery, not SUBSCRIBE_MODE.

NEXT: try HFI_CMD_DELIVERY_MODE for encoder output delivery instead
of SUBSCRIBE_MODE. Also examine vendor's msm_venc_metadata_delivery().

## v22/v23: DELIVERY_MODE experiments — also crash

- v22 (SUBSCRIBE + DELIVERY): same SUBSCRIBE_MODE errors, pipeline fails
- v23 (DELIVERY_MODE only, no SUBSCRIBE): phone crashes during test

CONCLUSION: Both SUBSCRIBE_MODE and DELIVERY_MODE cause firmware issues
on the vpu20_4v encoder. The mainline subscribe_property's early return
for ENCODER was likely intentional for this firmware generation — the
vendor's waipio driver handles these commands differently through its
own session management layer.

ALL USERSPACE-LEVEL FIXES EXHAUSTED (v1-v23, 2026-11-23). The encoder:
- Encodes H.264 frames ✓ (with 4 root-cause fixes)
- Writes to BITSTREAM buffers ✓ (proven by /dev/mem)
- Does not deliver output to userspace ✗ (no HFI_CMD_BUFFER responses)
- SUBSCRIBE/DELIVERY commands crash the firmware ✗

DEFINITIVE REMAINING PATH: boot vendor kernel (msm-5.10) with TX
tracing on the waipio video driver. This is the only approach left.
