# Experimental patches — NOT in the build

prepare-kernel.sh applies only `kernel/patches/*.patch`; nothing in this
directory is ever built into a kernel image.

- `0106-EXPERIMENT-media-iris-encoder-session-tracing.patch` — the iris
  encoder bring-up experiment (encoder re-registered on SM8450 + full HFI
  TX/RX tracing + a `venc_skip` module param to skip properties by id).
  Never boot this without `modprobe.blacklist=qcom_iris` on the cmdline:
  see KNOWN_ISSUES.md "r55 incident". Session state (2026-11-22): with
  PROFILE/LEVEL skipped via venc_skip the session passes HFI_CMD_START
  and dies while the first input buffers are queued; trace logs in
  hm6-study/enc-exp*.log.
