# Vendor video driver study — SM8450/SM8475 encoder/decoder ground truth

Systematic comparison of OEM msm-5.10-era video implementations against our
mainline iris port, 2026-11-23. Sources on the build server
(`~/k50ultra/vendor-kernels/`), key trees mirrored on the Mac
(`video-study/`).

**Status 2026-11-24 — read with `VIDEO-ENCODER.md`.** Three statements below
did not survive the hardware tests of the second campaign:

- "Encoding works on mainline anyway" (context bank section) is wrong: the
  encoder resets the SoC on frame 0, and routing the ARP buffer through SID
  0x2184 did not change that.
- The subscribe/delivery choreography was implemented (EXPERIMENT-0108); the
  firmware accepts it, the encoder still resets.
- `HFI_PROP_PROFILE`/`HFI_PROP_LEVEL` are still sent as 0/0: the sender is the
  control handler `iris_set_profile()`, which EXPERIMENT-0105 does not touch.

What stands: the DT and context-bank facts, the vendor command sequence,
and the buffer-size formulas.

## Sources

| Source | What it is | Notes |
|---|---|---|
| `moto-video` (MotorolaMobilityLLC/vendor-qcom-opensource-video-driver, tag android13 t1sq33) | Complete Qualcomm video-kernel module repo: `vidc/src` core + `variant/iris2` + `platform/waipio` | **Primary reference** — same driver generation as diting stock (iris2) |
| `sony-video` (sonyxperiadev, video-kernel.lnx.5.0.r1-rel) | Same Qualcomm base, newer gen (kalama/pineapple tables) | HEAD commit: "Enable legacy driver for Waipio/Parrot" — **Sony dodged iris2 on the same silicon** and runs the legacy driver |
| `xiaomi-diting` (MiCode bsp-diting-s-oss) | Full kernel tree — but **no video driver inside** (GKI module split) and **no venus DT node in the OSS DTS** (release incomplete; EVA/CVP node only) | `diting-s-oss` branch is DTS-only |
| stock DTB (carved from untouched slot-b `vendor_boot_b.img`) | **The authoritative diting venus DT node** | 14 concatenated DTBs; ours is msm-id 0x213 (SM8475) = dtb02 |
| oneplus / moto kernel trees | GKI kernels, no inline video driver or OEM DTS | confirm the GKI split |

Architecture lesson: in the msm-5.10/GKI era the video driver is a separate
module repo (`vendor/.../video-kernel`), device DTS mostly unpublished —
OEM kernel trees alone are NOT enough; pair them with the module repo and
the stock DTB.

## DT comparison (stock diting venus node vs our mainline node)

Stock `qcom,vidc@aa00000` (from slot-b DTB):

- `compatible = "qcom,msm-vidc", "qcom,msm-vidc-waipio", "qcom,msm-vidc-iris2"`
- `vidc,firmware-name = "vpu20_4v"`, `pas-id = <9>`, reg `0xaa00000 0xf0000`, irq SPI 174
- `qcom,reg-presets = <0xb0088 0x0 0x11>` — masked write clearing bits 0x11 of
  0xB0088 on every power-up (vendor `__set_registers()`, called between clock
  scaling and `interrupt_init`). Mainline does the equivalent
  (`iris_vpu_set_preset_registers`, unmasked `writel(0, base+0xb0088)`) — **not a gap**.
- 4 clocks + `proxy-clock-names` + `clock-configs`, allowed rates 240/338/366/444 MHz
- **5 context banks** (see routing below)

## Context bank routing (vendor `msm_vidc_get_buffer_region`)

Non-secure session:

| Buffer | Vendor CB (stream) | Mainline |
|---|---|---|
| ENC INPUT (raw) | `venus_ns_pixel` (0x2187, LLC pagetable) | single NS stream |
| ENC OUTPUT (bitstream) | `venus_ns` (0x2180) | same single stream |
| **ARP (always)** | **`venus_sec_non_pixel` (secure, vmid 0xB)** | single NS stream |
| DEC INPUT (bitstream) | `venus_ns` | |
| DEC OUTPUT / DPB / VPSS | `venus_ns_pixel` | |
| BIN/COMV/NON_COMV/LINE/PERSIST/META | `venus_ns` | |

Vendor routes ARP internal buffers through a *secure* context bank even for
non-secure sessions. Whether that matters on mainline was tested on
2026-11-23: with SID 0x2184 translated through the iris context bank and the
buffer in the non-pixel pool, the encoder resets at the same point.

The stock node itself is in `video-reference/stock-diting-venus-node.dts`.

## THE FINDING: encoder streamon choreography

Mainline `iris_hfi_gen2_subscribe_change_param()` and
`iris_hfi_gen2_subscribe_property()` both **early-return for ENCODER** —
the mainline encoder sends no subscribe/delivery at all. The vendor
(msm_venc.c streamon_output/streamon_input) sends **four** commands before
each START, exact payloads:

streamon **CAPTURE** (bitstream port) —
1. `HFI_CMD_SUBSCRIBE_MODE`, `HFI_PAYLOAD_U32_ARRAY`,
   `[HFI_MODE_PROPERTY(2), HFI_PROP_PICTURE_TYPE(0x03000162),
   HFI_PROP_BUFFER_MARK(0x0300016c), HFI_PROP_WORST_COMPRESSION_RATIO(0x03000174)]`
2. `HFI_CMD_SUBSCRIBE_MODE`,
   `[HFI_MODE_METADATA(4)]` + metadata ids enabled in caps — waipio enc META
   caps all default DISABLE → payload is the single mode word

streamon **OUTPUT** (raw port) —
3. `HFI_CMD_SUBSCRIBE_MODE`,
   `[HFI_MODE_PROPERTY(2), HFI_PROP_NO_OUTPUT(0x0300016a)]`
4. `HFI_CMD_DELIVERY_MODE(0x0100000A)`,
   `[HFI_MODE_METADATA(4)]` (empty list by default)

All with `HFI_HOST_FLAGS_RESPONSE_REQUIRED | HFI_HOST_FLAGS_INTR_REQUIRED`,
per-port, before that plane's `HFI_CMD_START`.

This is the prime candidate for the missing output delivery: the fw likely
does not raise HFI_CMD_BUFFER (buffer-done) responses until the property
subscription / metadata delivery handshake configures what must accompany
each completed buffer. Our v19-v23 failures are explained by payload
malformation: decoder-scale property lists (ids unsupported for ENC
sessions) instead of the tiny vendor lists above.

Decoder symmetry: mainline DOES subscribe (PORT_SETTINGS_CHANGE + property
lists) for decoders and decode works; vendor sends the same for dec plus
metadata modes. The encoder skip in mainline is the asymmetry to fix.

## Kernel config

Vendor: `CONFIG_MSM_VIDC_WAIPIO=y`, `CONFIG_MSM_VIDC_IRIS2=y` (module repo
Kconfig; no other video knobs). Ours: `CONFIG_VIDEO_QCOM_IRIS=m`. No
config-level blockers — all differences are driver behavior.

## Action derived (v32)

Replicate the vendor choreography in mainline iris, encoder-only:

- `iris_hfi_gen2_subscribe_property()`: replace the ENCODER early-return
  with the two vendor lists above (OUTPUT plane → 3-prop list, CAPTURE
  plane → NO_OUTPUT list)
- add `HFI_MODE_METADATA(4)` define; new encoder-only metadata calls at the
  same points: SUBSCRIBE_MODE on CAPTURE plane, DELIVERY_MODE on OUTPUT
  plane, each `[HFI_MODE_METADATA]` single-word payload
- keep v31's four root-cause fixes and the polling workaround as fallback;
  if delivery works, polling sees zero non-empty buffers complete without
  fw responses and can be retired
