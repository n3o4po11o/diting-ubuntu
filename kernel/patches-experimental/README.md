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
  - Next: port the vendor's firmware debug log (HFI_PROP_DEBUG_LOG_
    LEVEL + SYS_DEBUG_CONFIG, msm_vidc_debug.c) into the experiment so
    the fw reports its own death reason at first-frame time.
