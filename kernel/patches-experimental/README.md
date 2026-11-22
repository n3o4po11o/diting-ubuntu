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
