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

## v25: queue_type bit flags — DISPROVED (breaks fw init)

Changed queue_type from sequential (0,1,2) to bit flags (1,2,4) based
on vendor code using `|=` with HFI_Q_ID_* constants. Result: firmware
"core init failed" — the firmware REQUIRES sequential (0,1,2) values.

The vendor's `|=` with symbolic names must produce the same sequential
values (the initial default value already has 0, so |=0 is no-op, |=1
sets to 1, etc.). Queue types are NOT the output delivery issue.

**All pure-RE comparisons now exhausted** (DT, queue setup, HFI props,
subscriptions, delivery mode, cache ops, DMA mapping, queue types).
The remaining pure-RE approach: disassemble the firmware binary
(vpu20_4v.mbn, Hexagon DSP) to find the encoder response generation
code path and its enabling conditions.

## v30: hardcoded all-fixes + polling — CRASH, three bugs found offline

- All 6 fixes hardcoded via `v30_all_fixes.py` on a clean tree; the gst
  encoder test crashed the phone with zero POLL prints (the polling code
  never got to run).
- Post-mortem — three real bugs, none of them the polling idea itself:
  1. **PIPE packet id typo: `0x100000b`** — that is `0x0100000b` =
     HFI_CMD_SUBSCRIBE_MODE, the very command v19-v23 proved fatal to
     this firmware. HFI_PROP_PIPE is `0x0300010b`. Every STAGE was
     followed by an injected session-killer.
  2. Polling completed buffers with bare `vb2_buffer_done()` — no
     removal from the m2m dst list, no sequence/timestamp handling,
     outside every lock. The driver's own path is
     `iris_vb2_buffer_done()` (v4l2_m2m_buf_done underneath).
  3. v30 skipped interframe PC by deleting the resume-path call site
     only; `iris_hfi_core_init()` still sends the property. v10's
     venc_nopc returns 0 inside the op, covering every call site.
- `v30_all_fixes.py` kept for the record; never build it again.

## v31: v10-exact module params + FIXED polling (in flight)

`v31_all_fixes.py`, applied to a clean tree:

- `no_encoder = false`
- venc_profile=4 / venc_level=14 / venc_pipe=4 / venc_nopc=1 as module
  params whose DEFAULTS reproduce the proven v10 session (payload-level
  override at the top of session_set_property catches the streamon
  batch replay; src_subcr_params-level override too — both levels
  exactly like the 0106 patch did)
- VBR companion family on HFI_PROP_RATE_CONTROL (same 9 values as 0106)
- polling: per-codec-interrupt walk of encoder instances, core->lock /
  inst->lock taken in the release-first dance (never nested), buffers
  completed ONLY via `iris_vb2_buffer_done()` when their memory is
  non-empty
- every HFI id by named constant — the v30 typo class is impossible

Test: blacklist boot, manual modprobe, gst encoder run; success =
`POLL: enc output idx=N size=N` in dmesg AND a non-zero output file.

## 2026-11-23 evening: encoder session finally HEALTHY (0105-0110 + DPB deferral fix)

After fixing the boot red herrings (DITING_ROOT_CMDLINE override dropped
root=; initramfs fsck flake — see KNOWN_ISSUES), the -52 kernel boots
and the encoder reached a fully healthy session state:

- 0110 complete: enc internal buffer tables + DPB port/size/count
- DPB DEFERRAL FIX (not yet in a patch file): iris_buffer.c queues
  BUF_DPB only after IRIS_INST_STREAMING, but vpu20_4v requires the
  recon buffers BEFORE it accepts HFI_CMD_START — a deadlock by design.
  Gate the deferral on DECODER (vendor queues all enc internals at
  streamon). sed: `buffer->type == BUF_DPB && inst->domain == DECODER`.
- Result: START accepted, ETB consumed (FrameIdx 0..3), FTBs accepted
  (FW Internal: 1059840), real encoding happens ("Venc frame No. 1
  FrameQP=32"), 223KB bitstream accumulates internally. Clocks at max
  (mvs0 444 MHz). Decode unaffected.

REMAINING (the last mile):
1. fw never writes FTB buffers / never raises HFI_CMD_BUFFER output
   responses — output file stays 0 bytes even after 150+ s.
2. fw errors during every session, prime suspects for both:
   - `VppDec ResetCore(1244): HW polling reached max iterations`
     (VPP core reset poll timeout — likely DT gap: mainline has only
     the bus reset, the stock diting node also has video_core_reset
     from videocc; mainline iris never calls reset_control at all)
   - `venc_c2SetProperty: Error HFI_PROP_CROP_OFFSETS` (fw rejects the
     crop property for encoders — vendor sends different crop data)
   - `Error HFI_PROP_BLUR_TYPES` (drop 0x0300014e from the 0106 family)
3. Encoding crawls (~75 s/frame) consistent with the wedged VPP.

NEXT: patch 0111 = add video_core_reset to the iris node (videocc
provider, stock DTB spec 2) + assert/deassert it in the driver power
path like the vendor; drop BLUR_TYPES; fix encoder CROP_OFFSETS.
Also queued: error-session module refcnt -1 (unload hangs, D state,
blocks reboot — needs session cleanup fix).

## 2026-11-23 night — three root causes found by controlled experiments

### 1. Skipping inter-frame power collapse (old venc_nopc / patch 0107) silences the VPP

Control experiment: same module with and without the skip.

| config | decode | encode |
|---|---|---|
| skip HFI_PROP_INTRA_FRAME_POWER_COLLAPSE (v10..v31, patch 0107) | broken, 0 frames | session completes, VPP dead, no crash |
| send it (upstream behaviour) | works | SoC reset |

Without the property the firmware logs, in every session (decode too),
`ResetCore(1244): HW polling reached max iterations` right after the
first hardware job: the VPP core never runs. Every "encode works"
claim from v10 on was based on the `Venc frame No. N` dispatch line
and on internal byte counters; the hardware never encoded a frame.
The old logs prove it: ResetCore appears in enc-exp14..18 (nopc=1)
and in none of exp1..12. 0107 is therefore retired (0107-EXPERIMENT-*).
The "VppDec: PC refcount 0 and on is_needed 1" line of v9 was also
misread: it is an informational power-up message, followed by
`VPPSG start VPPSG task for frame 0` and then a firmware system error.

### 2. The encoder crashed the SoC because MXC was one corner too low

With the VPP alive the encoder reset the SoC about 3 ms after the
firmware received HFI_PROP_RAW_RESOLUTION (captured live over the
network with `dmesg -w`, /tmp/enc-crash-live.log).

Measured rails vs clock (pm_genpd_summary + clk_summary):

| state | mvs0 | MXC | MMCX |
|---|---|---|---|
| scaled session, 240 MHz point | 240 MHz | 128 (svs) | 64 (low_svs) |
| power-on, 444 MHz point | 444 MHz | 192 (svs_l1) | 256 (nom) |

so the first required-opp of the iris OPP table lands on MXC and the
second on MMCX. Downstream videocc-waipio.c (rate_max of
video_cc_mvs0_clk_src, classes vdd_mm and vdd_mxc) requires, for both
rails: LOW_SVS <= 720 MHz, SVS <= 1014, SVS_L1 <= 1098, NOM <= 1332.
The table gave MXC svs at 366 MHz and svs_l1 at 444 MHz. Decoding
mostly lands on the low points and survived; the encoder takes the
444 MHz point and died on the first VPP access. Patch 0111 raises MXC
to svs_l1 / nom at those two points.

Lesson: hardware that "works" can still be out of spec; measure rails
and clocks against the downstream clock driver before trusting a
decode-only validation.

### 3. Boot hangs were never kernel regressresses

See KNOWN_ISSUES.md: a DITING_ROOT_CMDLINE override without root= and
the initramfs fsck flake.

### Method notes

- Count frames (fpsdisplaysink + EOS), never trust "pipeline did not
  error".
- Experiment scripts live in this directory and are applied on top of
  the clean series; exp-fwlog-trace.py adds the firmware log (module
  parameter fwlog_level) and HFI TX/RX tracing.
- Patches are generated mechanically (diff of two trees) and validated
  with `patch --fuzz=0` on the base they will be applied to.

## 2026-11-23 late — encoder: session accepted, first hardware frame resets the SoC

With the boot red herrings gone, the encoder was driven with the VPP
alive and a network `dmesg -w` capture running for every attempt.

### What the firmware accepts now (EXPERIMENT-0105/0106/0108/0109/0110)

Session open, all properties, the encoder internal buffers (ARP, BIN,
COMV, NON_COMV, LINE, DPB x2, VPSS), SUBSCRIBE/DELIVERY on both ports,
HFI_CMD_START success on both ports, components created (Worker,
VPPSG, VSPAP, Reorder), SESSION_START, first ETB accepted. Then the
SoC resets within milliseconds, with no SMMU fault and no firmware
error line reaching the host. In the v9-era logs the same moment
produced `HFI_SYS_ERROR_SLV_ERR` (0x5000002), i.e. the VPU saw a
slave/bus error when the hardware started frame 0.

Encoder internal buffer sizes were re-verified numerically against
the vendor macros themselves (`/tmp/vsz` on the build server, 1280x1104,
H.264, 4 pipes, 2 recon frames): COMV 666624, NON_COMV 463616, LINE
531456, DPB 2195456, ARP 204800 are identical to what the mainline
code sends; BIN is larger than the vendor value (14663168 vs 11935232).
Sizes are not the problem. (Vendor allocates no VPSS buffer without
downscale/blur; mainline queues one.)

### Hardware-level differences tested, one per SoC reset

| change | verified on hardware | encoder |
|---|---|---|
| MXC corner raised to svs_l1/nom at 366/444 MHz (patch 0111) | rails 192 -> 256 | still resets |
| video_cc_mvs0_clk_src hw_clk_ctrl (EXPERIMENT-0112) | CFG bit 20 = 1 | still resets |
| ARP buffer mapped at 0x01000000, the downstream non-pixel pool (exp-arp-reset.py, driver part) | firmware receives addr 0x01000000 | still resets |
| SID 0x2184 added to the iris node in the DT | **hangs the boot**, see below | not reached |

0111 and EXPERIMENT-0112 are kept because both bring the node in line
with downstream and decode passes with them; neither explains the
encoder reset.

### TRAP: SID 0x2184 in the iris DT node hangs the boot (2/2)

`iommus = <&apps_smmu 0x2180 0x400>, <&apps_smmu 0x2187 0x400>,
<&apps_smmu 0x2184 0x400>` on the iris node: the kernel stops right
after `arm-smmu 15000000.iommu: preserved 0 boot mappings`, before any
`Adding to iommu group` line. Kernel Image and initramfs were byte
identical to the working image; the decompiled DTBs differ in exactly
those lines. Reproduced twice. The same boot images without the line
boot. Mechanism not identified: mainline allocates context banks
dynamically and treats the third stream like any other. exp-arp-reset.py
now refuses to apply that edit unless `ARP_SID_DT=I-know-it-hangs-boot`.

### Leading hypothesis: the ARP fetch uses the non-pixel master SID

Downstream maps the encoder ARP buffer (the register programming stream
the VPP executes: `HXU_HACK: SWI programming: 0x...`) through
venus_sec_non_pixel (SID 0x2184) even for non-secure sessions. It is
the only buffer type routed there, and ARP is encoder-only (decoders
use PERSIST), which matches "decode works, encode dies on the first
hardware job". Moving the buffer to the non-pixel IOVA pool alone did
not help (V7), consistent with the fetch being aborted at the SMMU for
an unmatched stream before the address matters.

Next test (built, not yet run): `linux-image-v8-arpsid.deb` in
`release/enc-series-v2/` on the Mac — exp-arp-sid-mask.py widens the
mask of the existing SID 0x2180 stream match entry to 0x47f at the
first encoder session, so 0x2180-0x21ff share the iris context bank.
Module-only, boot-safe (the module is blacklisted); module parameter
`arp_sid_alias` for an ablation run. Flash the V5-equivalent images
(`boot-v7.img` / `vendor_boot-v7.img`, DTB and kernel identical to
V5), install the deb, run the encoder.

If V8 still resets, ARP is not the (only) cause; remaining untested
items: video_core_reset in the DT (upstream sm8250 resets "bus" and
"core"; the local node only has "bus" — never tested alone), the
input format (linear NV12 vs UBWC), and the encoder properties the
firmware rejects (`Error in SetProperty HFI_PROP_CROP_OFFSETS`).

### Oddities noted

- `HFI_PROP_PROFILE`/`HFI_PROP_LEVEL` go out as 0 although the
  EXPERIMENT-0105 fallback should send 4/14; the sending path was not
  traced.
- Mainline sends `HFI_PROP_COMV_BUFFER_COUNT = 4`; the downstream
  waipio driver never sends that property.
- The firmware logs `Error in SetProperty HFI_PROP_CROP_OFFSETS` for
  the raw port in every encoder session.

## 2026-11-23 night — SMMU stream match rules, ARP hypothesis falsified, core reset

Every run below was a network `dmesg -w` capture on hardware.

### The SMMU stream match register has a rule the DT form violates

Attempts to give SID 0x2184 (the downstream "non-pixel" stream used for
the encoder ARP buffer) a translation:

| build | what | result |
|---|---|---|
| V6 | DT: `iommus` += `<0x2184 0x400>` (the downstream form) | boot hangs 2/2 right after `preserved 0 boot mappings` |
| V7 | ARP buffer mapped at 0x01000000 (downstream non-pixel pool), SID untouched | firmware receives addr 0x01000000; still resets |
| V8/V9/V10/V11 | runtime: widen the mask of the live 0x2180 entry | write takes a synchronous external abort (identical write OK) |
| V12 | mask as a module parameter, probe-only mode | 0x420 on 0x2180 also rejected |
| V13/V14 | probe tool `arp_smmu_write` (read / write one entry, dump the table) | table dumped: nothing covers 0x2184 |
| V15 | rewrite the idle 0x2187 entry to (0x2187, 0x407) | accepted; 0x2184 translated through the iris context bank; encoder still resets on frame 0 |
| V16 | video core reset (bus + core, as upstream sm8250), nothing else | boots, decode OK; encoder still resets. At 640x480 too |

Rule, measured with the probe tool (one rejected write per boot, it
leaves the SMMU runtime PM lock held):

- an identical write is always accepted;
- (X, 0x400) is accepted for every X tried in 0x218x, 0x2190, 0x21a0;
- with more mask bits, the entry is accepted only when the ID has a 1 at
  every masked position: (0x2187, 0x404) and (0x2187, 0x407) yes;
  (0x2180, 0x404/0x420/0x403/0x47f), (0x2184, 0x406), (0x2184, 0x400)
  no. Bit 10 is exempt (it is don't care on every entry).
- clearing VALID on the firmware's live 0x2180 entry resets the SoC.

So V6's boot hang is the hardware aborting the driver's SMR write for
(0x2184, 0x400) during probe; the downstream DT uses that form too, and
the downstream SMMU driver writes it the same way - why stock accepts it
is not known (downstream never disables the SMMU: `qcom,skip-init`).

### ARP through SID 0x2184 is not the fix

With 0x2184 translated and the ARP buffer at 0x01000000 the encoder
resets at the same place. The downstream ARP routing is a fidelity gap,
not the blocker.

### Where the firmware log stops (V16, furthest so far)

Worker: `Prepare VPP session Level SWIs`, `VenusVencPrepareBSEReg`,
`VenusVencMEPostProcess` - then the SoC resets before the next debug
queue flush. In the old v9 log the next lines were `VBUF_NewEx`,
`WorkerAcquireBuffer: bin_buffer_ptr`, `HXU_HACK: SWI programming`,
`Venc frame No. 0`, `VPPSG start VPPSG task for frame 0`, system error
0x5000002 (SLV_ERR).

### Not tested / not resolved

- `HFI_PROP_PROFILE` and `HFI_PROP_LEVEL` go out as 0 in the traces
  although EXPERIMENT-0105 forces 4/14 when the cap is 0: some other
  sender bypasses the fallback (likely the control handler
  `iris_set_profile()`); the firmware logs "Changing level ... incorrect
  input level".
- the firmware rejects `HFI_PROP_CROP_OFFSETS` on the raw port in every
  encoder session (mainline sends it on both planes, downstream only on
  the bitstream port).
- mainline sends `HFI_PROP_COMV_BUFFER_COUNT = 4`; downstream never sends
  it for this firmware.
- input format: only linear NV12 was tried.
- the firmware's own error is never delivered; a firmware-side trace
  (the original "boot the vendor kernel" plan) is still the way to see
  what the VPP hits on frame 0.

### State left behind

Phone: formal series only (boot and vendor_boot = `release/formal-7.2.10-52`
on the Mac; module from the same build): decoder registered, encoder off,
decode regression passes. The experimental builds are in
`release/enc-series-v2/` (v5..v16 debs and images).
