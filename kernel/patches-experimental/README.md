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
