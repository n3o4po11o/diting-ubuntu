# Debugging

No UART is known on this phone (vendor cmdline has `msm_geni_serial.con_enabled=0`;
no documented test points). Debug channels, in order of usefulness:

1. **USB gadget** (`diting.debug=usb|hold`): NCM network 172.16.42.1 ↔ host
   172.16.42.2, ACM serial `/dev/ttyACM0` with a root shell. Requires dwc3 +
   eUSB2 PHY + PTN3222 to work.
2. **pstore/ramoops** at the vendor location and layout: `console-ramoops-0` (kernel
   console) and `pmsg-ramoops-0` (dmesg snapshots from the initramfs). Readable from
   Android after a warm reset (`/sys/fs/pstore`), see SAFE_TESTING.md.
3. **Screen** via simpledrm on the ABL splash buffer (`console=tty0`). The panel is a
   DSC command-mode panel; without a panel driver the image may freeze at the last
   splash frame. A black or frozen screen is *not* evidence of a hang.
4. Once Ubuntu runs: persistent journal (`/var/log/journal`) and `systemd-pstore`.

Useful kernel args for experiments (add via `--cmdline`/`ROOT_SPEC`):
`ignore_loglevel`, `initcall_debug`, `printk.devkmsg=on`, `panic=0` (keep a panic on
screen), `rd.debug`-style output: `debug`.

## Watching the GPU and the video core

Qualcomm ships no tool for this on Linux, and there is no single
equivalent of `nvidia-smi`. What there is, read on the phone
(2026-11-28, kernel 7.2.10, Mesa 26.0.8, `glmark2-es2-wayland` as the
load):

- **`nvtop`** (3.2.0 from the archive) works. It shows the GPU load
  graph, the clock, and per process the GPU share and memory:
  `glmark2` at 45 per cent in its list against 50 per cent from the
  kernel's counters a moment later, the clock at 220 MHz and the GPU
  suspended when idle and at 900 MHz under load. It names the GPU
  "Unknown Adreno ffff07030001" (its name table has no `0x07030001`),
  prints the system RAM under MEM, and shows no temperature, power or
  fan - nvtop says it does not report those for MSM GPUs yet. Its MSM
  notice asks for Enter at every start.
- **`btop`** (1.4.6) shows no GPU on this kernel. It does not recognise
  the upstream driver's interfaces; probably it reads Qualcomm's
  downstream kgsl one, `/sys/class/kgsl`, which is absent here.
- **By hand**: `/proc/<pid>/fdinfo/<fd>` of any process holding the
  render node - `drm-cycles-gpu` (GPU cycles spent for that client; its
  growth over time against `drm-maxfreq-gpu` is the client's share),
  `drm-engine-gpu` (nanoseconds), `drm-total-memory` and its kind; the
  clock and power state under `/sys/class/devfreq/3d00000.gpu/`
  (`cur_freq`, `device/power/runtime_status`; the `load` file stays
  empty); the driver's own view under `/sys/kernel/debug/dri/128/`
  (`gpu`, `clients`, `client-*/proc_info`; root).
- **The video core** has nothing of the kind. Its load is the growth of
  the `video-codec` line in `/proc/interrupts` (about 60 a second for
  1080p30 decoded in hardware, zero for software decoding; the line
  appears with the first session), whether the decoder device is held
  open, and whether the core is awake
  (`/sys/bus/platform/devices/aa00000.video-codec/power/runtime_status`).
