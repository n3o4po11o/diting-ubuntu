# Video encoder (SM8450/SM8475 iris, Gen2 firmware): status, routes, sources, plan

Where the hardware encoder stands, every route that was tried, where the
sources are, and what to do next. Written 2026-11-24, after two campaigns.
Companion documents:

| Document | Content |
|---|---|
| `patches-experimental/README.md` | the chronological experiment log (v1–v31, then V2–V16) |
| `VIDEO-VENDOR-STUDY.md` | downstream msm_vidc (waipio/iris2) compared with mainline: DT, context banks, encoder streamon choreography |
| `video-reference/stock-diting-venus-node.dts` | the vendor video node, decompiled from the stock DTB (slot B) |
| `ubuntu-diting/docs/KNOWN_ISSUES.md` | "Video" sections: the traps, the reboot hang, browser decoding |

## 1. Status

| | |
|---|---|
| Kernel | upstream stable v7.2.10 + 105 local patches (`kernel/patches/0001`–`0104`, `0111`). **Series 7.2 is end of life** (7.2.15, 2026-11-01, was the last release); current stable is 7.3.6 |
| Video hardware | "IRIS2" (VPU 2.0) core, 4 pipes, at `0xaa00000`: the core generation of SM8250 |
| Firmware | `vpu20_4v.mbn` (video-firmware.2.4): **Gen2 HFI on a VPU 2.0 core**. Taken from the device (`qcom/sm8475/xiaomi/diting/vpu20_4v.mbn`); the linux-firmware we ship has `vpu20_p1_gen2` (SC7280) but nothing for the 4-pipe core |
| Driver | mainline `drivers/media/platform/qcom/iris` + local patches 0077–0084, 0111 |
| Decoder | **works** on the formal series: H.264, HEVC, VP9, bit-exact against ffmpeg; VA-API through `libva-v4l2-stateful` |
| Encoder | **not registered** in the formal series (0081). With the experimental series the firmware accepts the whole session, and the **SoC resets when frame 0 is handed to the VPP**. No SMMU fault and no firmware error line reaches the host |
| Upstream | no SM8450 video support at all (no DT node, no binding, no platform data). Since 7.3 upstream supports VPU 2.0 cores with Gen2 firmware (Milos, SC7280) with the encoder enabled: the reference for this port |

## 2. The stack

### 2.1 What the local patches do

| Patch | Content |
|---|---|
| 0077 | binding: `qcom,sm8450-iris` |
| 0078 | `sm8450_data`: firmware descriptor (`iris_vpu20_p4_gen2_desc`), VPU 2.0 ops, decoder buffer table, MXC/MMCX OPP rails |
| 0079 | DT node from the vendor `qcom,vidc` node; enabled on diting with `firmware-name` pointing at the device image (no file exists under the descriptor's default name in the linux-firmware we ship) |
| 0080 | decoder fixes for this firmware: `HFI_CMD_RESUME` without payload, no partial-data buffer |
| 0081 | do not register the encoder on SM8450 (`no_encoder = true`) |
| 0083, 0084 | decode-order output control; out-of-bounds timestamp metadata read |
| 0111 | iris OPP table: MXC raised to SVS_L1 / NOMINAL at 366 and 444 MHz (was out of spec) |

### 2.2 Where the SM8450 data comes from

`sm8450_data` is assembled from two platforms: VPU ops, clock and bandwidth
tables from SM8250 (VPU 2.0, Gen1 firmware); instance capability tables and
session property lists from SM8550 (VPU 3.x, Gen2 HFI). That mix was a guess.

Upstream answered the question in the meantime. **Milos (SM7635, VPU 2.0 core,
firmware `vpu20_p2_gen2_s7.mbn`) uses exactly the SM8550 encoder data** with
`iris_vpu2_ops` (commit `a9aba94a7ba6`, merged with 7.3):

- `inst_fw_cap_milos_enc`: the same 63 entries as `inst_fw_cap_sm8550_enc`
  with the same defaults and callbacks; only maxima differ (bitrate
  100 Mbit/s instead of 245, H.264 level 5.1 instead of 6.0, HEVC level 5
  instead of 6.2);
- `sm8550_venc_input_config_params` / `sm8550_venc_output_config_params`;
- `sm8550_enc_ip_int_buf_tbl` / `sm8550_enc_op_int_buf_tbl` — the tables
  EXPERIMENT-0110 adds for us.

So the Gen2 encoder session mainline sends for SM8550 is upstream's session
for VPU 2.0 + Gen2 as well; no capability table has to be written. What
differs between Milos and our platform data:

| | Milos (upstream) | SM8450 (0078) |
|---|---|---|
| pipes (`num_vpp_pipe`) | 2 (half fused off) | 4 |
| encoder | enabled | disabled by 0081 |
| OPP rails | `cx`, `mx` | `mxc`, `mmcx` |
| reset table | `iris_clk_reset_table_vpu2` | `bus` only (adding `core` tested in V16, no effect) |
| firmware | `vpu20_p2_gen2_s7` | `vpu20_4v` |
| kernel fixes after 7.2.10 | present | missing (§5.2) |

SC7280 got the same treatment ("kodiak Gen2" series, v3 on 2026-03-31): its
cover letter reports the Iris Encoder passing v4l2-compliance 52/52 with the
Gen2 firmware, next to the decoder.

## 3. Routes explored

### 3.1 First campaign: v1–v31 (2026-11-22/23)

Branch `x86_64-build`, commits `3d2f438`…`473d143`; log: README §v1–v31.

| Route | Result at the time | Verdict today |
|---|---|---|
| Inject session properties one by one (profile/level forcing, PIPE=4, VBR companion family, MIN_OUTPUT_COUNT, QUALITY_MODE, TIER, ROTATION) | each removed one hang point; no output ever | unreliable: the VPP was dead in all of these runs (next row) |
| Skip `HFI_PROP_INTRA_FRAME_POWER_COLLAPSE` (v10 "breakthrough", patch 0107) | firmware "encodes", phone survives | **retracted**: without it every session, decode included, logs `ResetCore(1244): HW polling reached max iterations` and no frame is ever processed |
| Output delivery: buffer-done traces, metadata buffers, cache, DMA, `/dev/mem` inspection | no `HFI_CMD_BUFFER` for BITSTREAM; "data appears" was a timing artifact | meaningless with a dead VPP |
| SUBSCRIBE / DELIVERY_MODE (v19–v23) | sessions died (`session error 0x100000b`) | redone as EXPERIMENT-0108 in the second campaign: accepted, encoder still resets |
| `queue_type` as bit flags (v25) | firmware init failed | firmware needs sequential values |
| Hard-coded variants v30/v31 with output polling | v30 crashed: PIPE was injected with the id `0x100000b`, which is `HFI_CMD_SUBSCRIBE_MODE` (PIPE is `0x0300010b`); v31 never evaluated | — |
| "The SM8550 capability table is wrong for this firmware" (ported waipio caps planned) | never done | settled by upstream: Milos uses the SM8550 table unchanged (§2.2) |

### 3.2 Second campaign: V2–V16 (2026-11-23)

Branch `encoder`; log: README §"2026-11-23 evening" to the end. Base: formal
series + EXPERIMENT-0105/0106/0108/0109/0110 + firmware log, with the VPP
alive (power-collapse property sent again).

| Build | Change | Verified on hardware | Encoder |
|---|---|---|---|
| V2–V5 | encoder session completed: internal buffers, subscribe/delivery, START on both ports, ETB accepted | firmware log shows Worker/VPPSG/VSPAP/Reorder created | **SoC reset on frame 0**; older captures show `HFI_SYS_ERROR_SLV_ERR` (0x5000002) there |
| V6 | DT: `iommus += <0x2184 0x400>` | — | hangs the boot, 2 of 2 |
| V7 | ARP buffer mapped at `0x01000000` (downstream non-pixel pool) | firmware receives the address | still resets |
| V8–V14 | SMMU stream-match register probes (§4.1) | rule found | — |
| V15 | SID 0x2184 translated through the iris context bank, ARP in the non-pixel pool | accepted | still resets: the ARP hypothesis is falsified |
| V16 | video core reset (`bus` + `core`, as upstream sm8250) | boots, decode OK | still resets; also at 640x480 |
| 0111 | MXC corner raised to the downstream level | rails 192 → 256 | still resets (kept: it was out of spec for decoding too) |
| 0112 | `hw_clk_ctrl` on `video_cc_mvs0_clk_src` | CFG bit 20 set | still resets (kept as an experiment) |

### 3.3 Never tested with a working VPP

- **The minimal session**: EXPERIMENT-0109 + 0110 only, which is what upstream
  Milos sends. Every V2–V16 build carried 0105/0106/0108 on top: PIPE=4, the
  VBR companion family (among it `TIME_DELTA_BASED_RC = 1`), and the
  subscribe/delivery handshake. None of these is part of the upstream
  session; upstream later set time-delta rate control to 0 on purpose.
- The upstream fixes that landed after 7.2.10 (§5.2), first of all the AHB
  bridge reset before switching the core power domain to hardware mode.
- LLCC: the stock node has `cache-slice-names = "vidsc0"`, a third
  interconnect path `venus-llcc`, and `qcom,iommu-pagetable = "LLC"` on every
  context bank. The mainline node has none of the three.
- UBWC input (only linear NV12 was ever queued).
- What the firmware writes into its SFR buffer and its debug queue at the
  moment of the crash (§6, phase B).
- The encoder with fewer than 4 pipes. Upstream runs Gen2 on 1-pipe (SC7280)
  and 2-pipe (Milos) cores only.

### 3.4 Traps

Each of these cost a boot or a day.

1. Never skip `HFI_PROP_INTRA_FRAME_POWER_COLLAPSE`: it disables the VPP for
   decoding as well.
2. Never list SID 0x2184 in the iris DT node as `<0x2184 0x400>`: the boot
   stops after `arm-smmu 15000000.iommu: preserved 0 boot mappings` (§4.1).
3. At runtime, a stream-match write whose ID is not the top of its mask range
   takes a synchronous external abort and leaves the SMMU runtime-PM lock
   held, so the next driver probe hangs: one rejected probe per boot. Clearing
   VALID on the firmware's live 0x2180 entry resets the SoC.
4. `DITING_ROOT_CMDLINE` replaces the whole cmdline. An override without
   `root=PARTLABEL=userdata` leaves PID 1 waiting forever; the initramfs then
   also needs the fsck binaries (`FSTYPE=ext4` in the device package, checked
   by `make verify` since 2026-11-23).
5. Test by counting frames (fpsdisplaysink + EOS). "The pipeline did not
   error" proved nothing twice.
6. No global boot parameter changes for debugging (`printk_delay` in a daily
   image was the r55 incident). Debug cmdline only in one-off images that
   also carry `modprobe.blacklist=qcom_iris`.
7. `prepare-kernel.sh` trusts `work/kernel-src/.diting-stamp`: an edited tree
   is rebuilt as "formal" as long as the stamp exists. On 2026-11-24 the
   kernel package on the build server, built as "formal" the evening before,
   turned out to carry experiment code in `qcom-iris.ko` for that reason
   (unreachable with the encoder unregistered). Use
   `patches-experimental/exp-build.sh`, which re-exports first and checks
   the tree.
8. Removing the module after it was used deadlocks; reboot instead.
9. SoC resets leave no pstore. Capture `dmesg -w` live over the network, and
   expect the UFS controller to wedge after a series of crash loops (rescue:
   forced power-off, cold boot).
10. HFI ids by named constant; patches generated mechanically (diff of two
    trees) and applied with `--fuzz=0`.

## 4. Reference data measured on this device

### 4.1 Apps SMMU stream-match rule

Stream match register `0x800 + 4n` on the apps SMMU (`0x15000000`): ID in
bits 14:0, mask in 30:16, VALID bit 31. While the SMMU is enabled:

- an identical write is always accepted;
- mask `0x400` is accepted for every ID tried in `0x218x`…`0x21a0`;
- with more mask bits the write is accepted only if the ID has a 1 at every
  masked position: `(0x2187, 0x404)` and `(0x2187, 0x407)` yes;
  `(0x2180, 0x404/0x420/0x403/0x47f)`, `(0x2184, 0x400/0x406)` no.
  Bit 10 is exempt on every entry.

So an entry must name the top of the range its mask covers. The stock DT
uses `<0x2184 0x400>` and the stock SMMU driver writes it the same way; why
stock accepts it is not known (downstream never disables the SMMU:
`qcom,skip-init`). Probe tool: `exp-smmu-probe.py` (module parameter
`arp_smmu_write`: `<sid>`, `<sid>:<register>`, `dump`), table dump in
`video-study/encoder-logs/sidmap-live.log`.

### 4.2 Rails and clocks

The first `required-opp` of the iris OPP table lands on MXC, the second on
MMCX (measured with `pm_genpd_summary` + `clk_summary`). Downstream
`videocc-waipio.c` requires MXC and MMCX at least at SVS_L1 up to 1098 MHz
and NOMINAL up to 1332 MHz of `video_cc_mvs0_clk_src`. 0111 raises the table:

| OPP | MXC (was → now) | MMCX |
|---|---|---|
| 240 MHz | SVS | LOW_SVS |
| 338 MHz | SVS | SVS |
| 366 MHz | SVS → **SVS_L1** | SVS_L1 |
| 444 MHz | SVS_L1 → **NOMINAL** | NOMINAL |

### 4.3 Encoder internal buffers

1280x1104 H.264, 4 pipes, 2 reconstruction frames. Our values and the vendor
formulas (`hfi_buffer_iris2.h`) agree, except BIN, where we allocate more:

| Buffer | Bytes | Note |
|---|---|---|
| COMV | 666624 | vendor formula = ours |
| NON_COMV | 463616 | vendor formula = ours |
| LINE | 531456 | vendor formula = ours |
| DPB | 2195456 per frame, 2 frames | vendor formula = ours |
| ARP | 204800 | encoder only (decoders use PERSIST); vendor = ours |
| BIN | 11935232 vendor, 14663168 ours | SM8550 formula, as upstream Milos |
| VPSS | — | vendor allocates none without downscale/blur; mainline queues one |

### 4.4 Where the firmware log stops

V16, the furthest run: Worker `Prepare VPP session Level SWIs`,
`VenusVencPrepareBSEReg`, `VenusVencMEPostProcess` — then the SoC resets
before the next debug-queue flush. In the v9-era log the next lines were
`VBUF_NewEx`, `WorkerAcquireBuffer: bin_buffer_ptr`,
`HXU_HACK: SWI programming`, `Venc frame No. 0`,
`VPPSG start VPPSG task for frame 0`, system error `0x5000002`.

### 4.5 Stock and mainline DT node

Stock (`video-reference/stock-diting-venus-node.dts`): 4 clocks with proxy
clock list, allowed rates 240/338/366/444 MHz, resets `video_axi_reset` and
`video_core_reset`, `vcodec-supply` and `iris-ctl-supply`, `vidsc0` cache
slice, three interconnect paths, `qcom,reg-presets = <0xb0088 0 0x11>` (bits
0 and 4 cleared at every power-up; mainline writes 0 to the register unmasked),
and five context banks:

| Context bank | SID, mask | Pool | Secure |
|---|---|---|---|
| `venus_ns` | 0x2180, 0x400 | 0x25800000 + 0xba800000 | no |
| `venus_ns_pixel` | 0x2187, 0x400 | 0x00100000 + 0xdff00000 | no |
| `venus_sec_non_pixel` | 0x2184, 0x400 | 0x01000000 + 0x24800000 | yes, VMID 0x0b |
| `venus_sec_bitstream` | 0x2181, 0x404 | 0x00500000 + 0xdfb00000 | yes, VMID 0x09 |
| `venus_sec_pixel` | 0x2183, 0x400 | 0x00500000 + 0xdfb00000 | yes, VMID 0x0a |

Mainline: GDSCs MVS0C (`venus`) and MVS0 (`vcodec0`), MXC and MMCX, clocks
`iface`/`core`/`vcodec0_core`, interconnects `cpu-cfg` and `video-mem`, reset
`bus`, SIDs 0x2180 and 0x2187, `dma-coherent`.

## 5. Upstream state (checked 2026-11-24)

### 5.1 Releases

| Series | State |
|---|---|
| 7.2 | end of life, last 7.2.15 (2026-11-01); **we build 7.2.10** |
| 7.3 | stable, 7.3.6 (2026-11-23); contains the VPU 2.0 + Gen2 work (merge `media/v7.3-1`, 2026-08-19) |
| 7.4 | in rc |

### 5.2 Commits that matter, against our v7.2.10 base

"Applies" was tested with `git apply --check` on pristine v7.2.10 on
2026-11-24.

| Commit | Title | In 7.2.10 | Applies | Relevance |
|---|---|---|---|---|
| `a9aba94a7ba6` | Add support for Milos (VPU v2.0) | no | no (needs the 7.3 platform-data layout) | the reference: VPU 2.0 + Gen2, encoder enabled |
| `a9ff61527805` | Add Gen2 firmware autodetect and fallback | no | no | classifies `video-firmware.N.M` with N ≥ 2 as Gen2; DT override keeps priority |
| `3395d7526386` | Initialize HFI ops after firmware load in core init | yes | — | — |
| `4278c4e87a2f`, `e53f8feb2e40`, `92b9674e4754`, `c60ced8bd1cd` | Agatti / AR50LT core, Gen1 and Gen2 | no | no | another Gen2-on-old-core port |
| `f2a793f2f386` | vpu op hook to disable ARP buffer | no | no | AR50LT: ARP must be disabled "so firmware can configure the ARP internal buffer as non-secure for encoder usage" — the same area as the vendor's secure non-pixel routing of ARP |
| `cc330f558996` | reset AHB bridge before enabling HW mode | no | **yes** | stale bridge FIFO when the core domain goes to hardware mode; Cc stable |
| `9cfae7726a9a` | Fix power-off ordering (power domain after clocks) | no | **yes** | clock writes to an unpowered controller "can hang"; Cc stable |
| `95f9e9fc9336` | guard against a NULL hfi_sys_ops in the interrupt handler | no | **yes** | NULL dereference on an early interrupt |
| `f301102c17f2` | fail firmware boot on invalid uc_region | no | **yes** | reported success on a firmware that never booted |
| `af5f7df6c8b3` | reference count video instances | no | no, port | use-after-free between the IRQ thread and close(); possibly behind the unload/shutdown hang |
| `6eec0f9b5c31` | disable time-delta-based rate control for VBR | no | no, port | the firmware defaults to time-delta RC **enabled**; upstream now sends 0. Our 0106 sends 1 |
| `a6ee1766b3db` | force stage 1 work mode for CBR on encoder | no | no, port | only CBR |
| `b9c2215bdedc`, `f87d7eda07fc`, `75d79879ec3c` | disable_irq on power-off; runtime PM leaks; resume failure in deinit | yes | — | — |

The four that apply are stored as `patches-experimental/UPSTREAM-*.patch`
(untested on the device until `minfix` is run).

Maintainers (MAINTAINERS, "QUALCOMM IRIS VIDEO ACCELERATOR DRIVER"): Vikash
Garodia, Dikshita Agarwal, R: Abhinav Kumar; lists `linux-media@vger.kernel.org`,
`linux-arm-msm@vger.kernel.org`.

## 6. Plan

Ordered by cost per answer. Every experiment that touches the encoder needs
the blacklist image and a live `dmesg -w` capture (§7).

### Phase A — the session itself (module-only, one boot each, builds exist)

| # | Build | Question |
|---|---|---|
| A1 | `min`: EXPERIMENT-0109 + 0110 + firmware log | Does the session upstream Milos sends reset too? |
| A2 | `minfix`: A1 + the four UPSTREAM fixes | Does the AHB bridge reset / power-off ordering change it? |
| A3 | A1, and the test program sets H.264 profile and level explicitly (`v4l2-ctl --set-ctrl`, names from `v4l2-ctl -l`, or GStreamer's `extra-controls` property) | Is the crash caused by PROFILE/LEVEL going out as 0/0? (traces show 0 although the table default is High / 5.0; the sender is `iris_set_profile()` in `iris_ctrls.c`, which passes the cap value through) |
| A4 | A1 + a port of `6eec0f9b5c31` (time-delta RC = 0) | upstream's value instead of the firmware default |
| A5 | A1 + 0106 without the PIPE injection; then with PIPE | which part of the old "fixes" matters |
| A6 | A1 + 0108 | same, for subscribe/delivery |
| A7 | A1, `HFI_PROP_CROP_OFFSETS` only on the bitstream port (the firmware logs "Error in SetProperty HFI_PROP_CROP_OFFSETS" for the raw port in every session) and no `HFI_PROP_COMV_BUFFER_COUNT` (downstream never sends it) | the two remaining known session defects |

For each: run the decode regression first, then the encoder, and compare
where the firmware log stops with §4.4. If A1 already differs from V16, the
cause is inside the add-ons; if A1 stops at the same place, the cause is
outside the session properties and phases B–D take over.

### Phase B — see what the firmware dies of

Today the last firmware lines are lost and no error reaches the host.

1. **Debug queue by polling.** The queue is drained only on interrupt
   (`iris_hfi_queue_dbg_read()` from the IRQ handler). Poll it from a thread
   every few milliseconds during encoder sessions, so lines written before
   an interrupt could be raised are still read.
2. **SFR buffer.** `core->sfr_vaddr` (4 KiB, write-combined) is handed to the
   firmware as the subsystem-failure-reason area; mainline never prints it.
   Dump it (hex + text) in the system-error and watchdog paths and from the
   polling thread after the ETB of frame 0.
3. **Do not recover at once.** On a firmware system error the driver powers
   the core off right away. Skip that for a few seconds (module parameter)
   and check whether the phone survives: if it does, the SoC reset is caused
   by the recovery path, not by the encoder.
4. **Last kernel lines.** `dmesg -w` over ssh loses the final milliseconds.
   Try netconsole over the USB network or the USB serial console.
5. **Reset reason.** After a crash reboot read `/proc/cmdline`: downstream
   SM8450 bootloaders pass a reset reason (`bootinfo.pureason`); not yet
   checked whether this one exposes it to a mainline boot. pstore stays empty
   on this phone even after a clean reboot.

### Phase C — platform level, not session level

- LLCC: enable the `vidsc0` slice for the video core, add the `venus-llcc`
  interconnect path (sm8450 LLCC and interconnect drivers exist), and look at
  what the "LLC" page-table attribute does in the downstream SMMU driver.
- Pipes: build with `num_vpp_pipe = 2` (or send PIPE = 1/2) to find out
  whether the 4-pipe encoder path is what dies; check what the waipio
  capability table says about PIPE for encoders (`msm_vidc_waipio.c`).
- UBWC input (QC08C) from a small test program.
- Read the power/clock state of the VPU at frame 0 (GDSC mode, MVS0 clock,
  the core's power-collapse counters) against what the vendor driver sets
  (`qcom,clock-configs`, GDSC in HW mode after firmware boot).

### Phase D — move to a maintained kernel and port upstream's structure

7.2 is EOL and the VPU 2.0 + Gen2 support lives in 7.3+. On 7.3.6:

1. rebase the 105 patches and the config (`make check-latest-kernel`,
   `update-kernel`), full regression (display, cameras, audio, modem,
   suspend);
2. rewrite 0078 on upstream's layout: `firmware_desc_gen1`/`gen2`, Gen2
   autodetect, `iris_platform_*` headers as Milos and SC7280 do; SM8450 =
   Milos pattern with 4 pipes, MXC/MMCX and the 8K limits;
3. 0077/0079 as an upstreamable DT/binding series (`qcom,sm8450-iris`);
4. drop EXPERIMENT-0110 (the 7.3 data carries the encoder tables).

This is the route to an upstream-submittable encoder; A–C can still be done
on 7.2.10 meanwhile.

### Phase E — ask upstream

To `linux-media@vger.kernel.org`, Cc the maintainers:

1. Is the Milos / SC7280 encoder validated by real encodes, and with which
   firmware build? (the SC7280 cover letter shows compliance only)
2. SM8450/SM8475 run `vpu20_4v`, a Gen2 image on the 4-pipe VPU 2.0. Known
   differences from the p1/p2 images, in particular for the encoder?
3. The encoder ARP buffer: downstream waipio routes it through a secure
   non-pixel context bank even for non-secure sessions, AR50LT disables ARP
   for encoder use. What is expected on VPU 2.0?
4. Interest in SM8450 iris support upstream (decode works today).

### Phase F — heavy routes, if A–E leave the question open

| Route | What | Cost |
|---|---|---|
| Firmware reverse engineering | `vpu20_4v.mbn` is a Hexagon ELF; `ubuntu-diting/tools/spf-re/` (LLVM Hexagon disassembly, ELF map, xref tools, built for the ADSP image) and the Ghidra bridge; start from the strings of the last log lines (`VenusVencPrepareBSEReg`, `VenusVencMEPostProcess`) | days; the encoder's frame-0 register programming is what has to be understood |
| Vendor kernel with tracing | boot the stock Android kernel with an instrumented msm_vidc and record one encoder session | needs a working Android on the device and a rebuilt vendor module |
| Port msm_vidc | run the downstream driver out of tree | largest; abandon mainline iris for encoding |

## 7. Running an experiment

### 7.1 Where things are

| Place | Path | Content |
|---|---|---|
| repo (Mac, the only source) | `kernel/patches/` | formal series, 105 patches |
| | `kernel/patches-experimental/` | `EXPERIMENT-0105…0112` patches, `UPSTREAM-*` fixes, `exp-*.py` scripts, `exp-build.sh`, the log |
| | `kernel/video-reference/` | stock venus node |
| build server | `~/k50ultra/diting-ubuntu/` (branch `encoder`) | checkout; `ubuntu-diting/work/kernel-src` is the patched tree |
| | `~/k50ultra/diting-ubuntu/kernel/upstream` | upstream git at v7.2.10 |
| | `~/k50ultra/vendor-kernels/` | `moto-video`, `sony-video`, `moto-dts`, `sony-dts`, `xiaomi-diting`, `xiaomi-dts`, `oneplus-sm8450`, `moto-sm8450`, `sm8450-mainline/{next,next-new}` |
| | `ubuntu-diting/output/experimental/<TAG>/` | experimental packages and images, by tag |
| Mac | `~/work/redmi-k50ultra/release/` | `formal-7.2.10-52/` (daily + debug images, clean package), `enc-series-v2/` (v5…v16), `enc-series-v3/` (`min`, `minfix`) |
| | `~/work/redmi-k50ultra/video-study/` | `moto-video/`, `sony-video/` mirrors; `iris/` is a **modified** copy (v31 state), not a reference; `encoder-logs/` live captures V2–V16 and the SMMU table dump; `upstream-iris-2026/` the commits of §5.2 |
| | `~/work/redmi-k50ultra/hm6-study/` | `enc-exp1…18.log` (first campaign), `enc_test.c`, `v4l2-ctl` helpers |

### 7.2 Build (server, in tmux)

```bash
ssh mt8788-build "tmux new-session -d -s k50ultra-build \
  'cd ~/k50ultra/diting-ubuntu && kernel/patches-experimental/exp-build.sh formal'"
# formal: exactly kernel/patches, default cmdline; also writes output/.formal-backup

ssh mt8788-build "tmux new-session -d -s k50ultra-build \
  'cd ~/k50ultra/diting-ubuntu && kernel/patches-experimental/exp-build.sh exp TAG \
     -p EXPERIMENT-0109 -p EXPERIMENT-0110 -p UPSTREAM -s exp-fwlog-trace.py'"
# exp: formal series, then the patches (fuzz 0) and the scripts; image with
# modprobe.blacklist=qcom_iris; result in output/experimental/TAG, the formal
# packages and images are restored.  -n = dry run, -p all = every EXPERIMENT patch
```

Logs in `ubuntu-diting/output/logs/exp-*.log`. Patches and scripts are
written locally and rsynced first (`kernel/patches-experimental/`); nothing
is edited on the server.

### 7.3 Flash and test

```bash
# via the Mac to the phone (172.16.42.1): the package from output/experimental/TAG
sudo dpkg -i linux-image-7.2.10-diting_7.2.10-52_arm64.deb
# boot.img / vendor_boot.img from the same directory by fastboot; back up the
# active slot's partitions before the first flash

# decoder regression first: expect PREROLLED, "Got EOS", RC=0
ffmpeg -y -f lavfi -i testsrc2=duration=2:size=848x480:rate=24 -c:v libx264 -pix_fmt yuv420p /tmp/dec.h264
timeout 40 gst-launch-1.0 filesrc location=/tmp/dec.h264 ! h264parse ! v4l2h264dec ! \
  fpsdisplaysink video-sink=fakesink text-overlay=false sync=false; echo RC=$?

# live kernel log from the Mac, started before the encoder
ssh -i ~/.ssh/diting_debug_key ubuntu@172.16.42.1 'sudo dmesg -w' > /tmp/enc-<TAG>-live.log 2>&1 &

# encoder (the module is blacklisted on test images: load by hand)
sudo modprobe qcom_iris
sudo sh -c 'echo module qcom_iris +p > /sys/kernel/debug/dynamic_debug/control'
nohup sh -c 'timeout 90 gst-launch-1.0 videotestsrc num-buffers=10 ! \
  video/x-raw,format=NV12,width=1280,height=1104,framerate=30/1 ! \
  v4l2h264enc ! h264parse ! filesink location=/tmp/enc.h264 > /tmp/gst.log 2>&1' &
# success = a non-empty /tmp/enc.h264, 10 buffers dequeued, phone alive
```

### 7.4 Safety

- Experimental images always carry `modprobe.blacklist=qcom_iris`; a phone
  that loops on the encoder reset is recovered with Vol-down + Power into
  fastboot and the formal pair (`release/formal-7.2.10-52/boot*.img`).
- After several crash loops the UFS controller can wedge: `poweroff -f` from
  the serial rescue shell (`diting.debug=usb`, `scripts/serial-fsck.py`) and
  a cold boot.
- Stale GStreamer registry after a hang: `rm ~/.cache/gstreamer-1.0/registry*.bin`.
- Never `pkill -f` a pattern that is part of your own ssh command.

### 7.5 State left on 2026-11-24

- Phone: formal series, daily images with the default cmdline
  (`release/formal-7.2.10-52/boot.img`, `vendor_boot.img`), decoder only.
  Not reachable over USB during this session, so not re-checked. If the
  installed kernel package came from the server's build of 2026-11-23 22:56
  instead of the archived one, `qcom-iris.ko` in it contains unreachable
  experiment code (ARP/SID-alias, encoder only): install the rebuilt formal
  package once to be sure.
- Server: checkout on `encoder`; formal package and images rebuilt and
  verified clean (`exp-build.sh formal`, 35 checks); `min` and `minfix`
  experimental builds in `output/experimental/` (§6, phase A).
- Repo: branch `encoder`. The first campaign's commits are only on
  `x86_64-build`.

## 8. Sources

### 8.1 Upstream

| What | Link |
|---|---|
| Stable tree and the base we build | https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git — tag `v7.2.10` |
| Tarball of the base (`config/kernel.lock`) | https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.10.tar.xz |
| Releases (7.2 EOL, 7.3 stable) | https://www.kernel.org/releases.json |
| Iris driver, mainline | https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/platform/qcom/iris |
| Binding | `Documentation/devicetree/bindings/media/qcom,sm8550-iris.yaml` |
| Milos, VPU v2.0 + Gen2 (the reference) | https://github.com/torvalds/linux/commit/a9aba94a7ba6 |
| Gen2 autodetect | https://github.com/torvalds/linux/commit/a9ff61527805 |
| AHB bridge reset before HW mode | https://github.com/torvalds/linux/commit/cc330f558996 |
| Power-off ordering | https://github.com/torvalds/linux/commit/9cfae7726a9a |
| SC7280 Gen2 ("kodiak"), cover letter | https://lwn.net/Articles/1065596/ — `20260331-kodiak-gen2-support-v3-0-958296fab838@oss.qualcomm.com` (v2 `20260227-…-v2-0-7e5b13d26542`, v1 `20260209-…-v1-0-390000a4fa39`) |
| Lists | https://lore.kernel.org/linux-media/ · https://lore.kernel.org/linux-arm-msm/ |
| Iris series since July 2026 | https://github.com/torvalds/linux/commits/master/drivers/media/platform/qcom/iris |
| Kernel tree mirror of this port (v7.2.10 + patches as commits) | https://github.com/royka1/linux-diting |
| Community mainline port (no SM8450 video node in its tree) | https://github.com/sm8450-mainline · https://wiki.nura.eco/wiki/Qualcomm_Snapdragon_8_Gen_1/8%2B_Gen_1/7%2B_Gen_2_(SM8450/SM8475/SM7475) |
| Qualcomm's video driver repository (README only checked: VPU driver with H.264/H.265 encode; platforms not listed) | https://github.com/qualcomm-linux/video-driver (`video.qclinux.main`) |
| Qualcomm msm-5.10 / video-kernel on CodeLinaro | requires an account |

### 8.2 Vendor sources (GKI era: the video driver is a separate module repository; OEM kernel trees alone are not enough)

| Source | What it gives | Local |
|---|---|---|
| MotorolaMobilityLLC/vendor-qcom-opensource-video-driver, tag `android-13-release-t1sq33.15-11-137-10` — https://github.com/MotorolaMobilityLLC/vendor-qcom-opensource-video-driver | **primary reference**: msm_vidc with `driver/variant/iris2` (buffer sizes `hfi_buffer_iris2.h`), `driver/platform/waipio` (capability table `msm_vidc_waipio.c`), `driver/vidc/src/` (`msm_venc.c`, `msm_vidc_buffer.c`, `msm_vidc_driver.c`, `hfi_packet.c`, `venus_hfi.c`, `venus_hfi_response.c`) | server `moto-video` (`c804e8b`), Mac `video-study/moto-video` |
| sonyxperiadev/vendor-qcom-opensource-video-driver, `video-kernel.lnx.5.0.r1-rel` — https://github.com/sonyxperiadev/vendor-qcom-opensource-video-driver | same base, newer generation; runs the legacy driver on Waipio | server `sony-video` (`28789f0`), Mac `video-study/sony-video` |
| MiCode/Xiaomi_Kernel_OpenSource, `bsp-diting-s-oss` — https://github.com/MiCode/Xiaomi_Kernel_OpenSource | `drivers/clk/qcom/videocc-waipio.c` (voltage corners), `drivers/iommu/arm/arm-smmu/`, `clk-rcg2.c`; no video driver | server `xiaomi-diting` (`cb7a356`) |
| MiCode, `diting-s-oss` | device DTS of the release: no waipio venus node | server `xiaomi-dts` (`df8603c`) |
| OnePlusOSS/android_kernel_oneplus_sm8450, `oneplus/sm8450_s_12.1_10_pro` — https://github.com/OnePlusOSS/android_kernel_oneplus_sm8450 | GKI kernel, no video driver | server `oneplus-sm8450` (`4b811fa`) |
| MotorolaMobilityLLC/kernel-msm `MMI-T1SJS33.117-30-3-9`, kernel-devicetree `MMI-T1SJS33.117-30-3-5` | same picture | server `moto-sm8450`, `moto-dts`, `sony-dts` |
| Stock DTB of this phone | the authoritative venus node (§4.5) | `video-reference/stock-diting-venus-node.dts`; source `device-data/images/vendor_boot_b.img` |

### 8.3 Tools

| Tool | Use |
|---|---|
| `exp-build.sh` | builds (§7.2) |
| `exp-fwlog-trace.py` | firmware debug log (`fwlog_level`) + HFI TX/RX trace via dynamic debug |
| `exp-arp-reset.py`, `exp-arp-sid-mask.py`, `exp-core-reset.py`, `exp-hwclkctrl.py`, `exp-smmu-probe.py` | the V6–V16 experiments, kept for the record |
| `v30_all_fixes.py`, `v31_all_fixes.py` | first campaign, never build again |
| `ubuntu-diting/tools/spf-re/` | Hexagon firmware analysis (LLVM), built for the ADSP image |
| `~/work/redmi-k50ultra/release/gmcp.py`, `ghidra-call.sh` | JSON-RPC clients for the local Ghidra MCP bridge (not used on the video firmware yet) |
