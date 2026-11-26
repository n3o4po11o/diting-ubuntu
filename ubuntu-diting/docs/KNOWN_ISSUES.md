# Known issues and risks

State as of 2026-10-21 (kernel 7.2.10-diting r46, device-xiaomi-diting 0.7.17,
firmware-xiaomi-diting 0.9.5, phosh 0.54.0-1diting1, diting-firmware-setup
0.1.1). Device evidence is
in `docs/BRINGUP_STATUS.md`.

## Open, device-confirmed

- **Charging state** (r44, patch 0091): the firmware reports the battery
  current as negative while charging, and upower 1.91 calls any battery with
  a negative `current_now` "discharging". The phone then showed discharging
  on the charger, and on 2026-10-15 at 2 % upower powered it off while it was
  plugged in. 0091 negates the value; DEVICE-TESTED on the stock fast charger:
  upower now reports charging, and unplugged discharging (-180 mA at 99 %).
  Not yet measured: charging from a low level (on 9 V / 1.16 A at 96 % the firmware reported
  USB type SDP, current_max 2 A).
- **GPU faults** still happen now and then: GMU HFI messages time out
  (`HFI_H2F_MSG_GX_BW_PERF_VOTE ... timed out`, a few per hour) and once,
  during a phone call, the GPU faulted (CP read of iova 0) and hangcheck
  started recovery. Before r44 (0090) recovery and the SMMU fault handler
  deadlocked on `gpu->lock`: phoc stayed in D state, the screen stayed dark
  and the power key did nothing until a reboot. With 0090 the GMU wait gives
  up after 1 s so recovery can finish; that path has not yet run on the
  phone. A second hang (under Waydroid) showed that recovery does run with
  0090 but the GMU never initialises again, so the screen still stays dark.
  Both hangs started when the GPU resumed from idle. r44 (0092) keeps the
  A730 powered for 1 s after it goes idle instead of 66 ms, as an
  experiment to make resumes rarer; whether it helps is not yet known.
- **Call audio** works in both directions on 3G calls, with Fluence echo and
  noise cancellation; calls start on the earpiece, the Calls app's speaker
  and mute buttons work (diting-callaudio replaces callaudiod, whose port
  switching cannot work here: PipeWire makes earpiece and loudspeaker, which
  share a PCM, exclusive profiles). Call volume is fixed: VCPM step 4 with
  volume boost (the calibration has steps 0..4; step 5 silences RX), and
  speakerphone calls run the amplifiers at Android's level (digital 0 dB,
  analog gain 17) while media keeps the -6 dB/minimum-gain setup; the
  owner finds speakerphone "enough, not very loud". During calls the volume
  keys set the amplifier level (earpiece up to +6 dB at minimum analog gain,
  loudspeaker up to +6 dB at analog gain 17 with the protection running); call and media volume are kept apart. Limits: the TX rate converters are fixed at 16 kHz (wideband) because VCPM
  does not apply the per-rate calibration entries, so narrowband (8 kHz)
  calls are untested; calls fall back to 3G (no VoLTE/IMS). The voice
  topology and ADSP modules come from the local firmware package; without
  it (or without fastrpc-diting) calls have no audio.
- While a call runs, media playback (MultiMedia1) is taken off the
  loudspeaker; media that is playing at the very moment a call starts can
  keep the speaker graph from attaching to the call.
- Ubuntu's `q6voiced` (qcom-phone-utils) and `wys` (phosh-phone) are for
  other platforms (q6voice); device-xiaomi-diting masks them.
- The ADSP audio PD can be created once per ADSP boot: diting-audiopd.service
  is started by udev and not restarted automatically.
- **Microphones** work (two analog mics, device package 0.5.1); the earpiece
  (top amplifier switched by gpio52) is not used yet.
- **Camera**: only the rear ultrawide (S5K4H7) works so far: raw capture and
  libcamera (simple pipeline, software ISP, 30 fps, patched libcamera with an
  S5K4H7 sensor helper). No colour tuning (CCM) yet, and auto exposure stops at
  one frame time (33 ms), so dim rooms stay dark. Its register tables come from the phone's vendor partition
  (`device-data/camera`, see tools/camera) into the local firmware package.
  The main camera (S5KHP1, 200 MP, MIPI C-PHY) streams too (libcamera camera
  2, 30 fps at 4096x3072) with contrast autofocus in the patched libcamera
  (continuous by default, about 3 s per scan; LensPosition is a 0..100
  scale, not dioptres). No colour matrix (CCM) yet. The video codec (iris/venus) has no SM8450/SM8475
  support in mainline: no hardware HEVC encode/decode; AV1 is not in this
  SoC's hardware. Front (IMX596) and macro
  (GC02M1) have no driver yet. The login screen's PipeWire also opens the
  cameras.
- **Sensors**: accelerometer (rotation), gyroscope, magnetometer/compass,
  light and proximity work through the SLPI (libssc + iio-sensor-proxy 3.9);
  the screen turns off at the ear during calls (owner-tested). The
  SLPI's `sns_registry` remote interface is not provided (answered with an
  error, harmless). Debugging: `adsp_diag --base 192` reads the SLPI's log.
- **Suspend efficiency**: suspend/resume works, but `qcom_stats` never shows
  CXSD/AOSD/DDR residency (counter layout on SM8475 unverified) and the drain
  test was inconclusive. While charging, ADSP glink notifications wake the phone
  after a few seconds. On battery the modem's QMI indications (network
  status) wake it every now and then (ftrace: ipcc/glink-smem as the first
  interrupt after resume); in 60 s RTC tests it slept the full period in about
  half of the cycles. ModemManager does not ask the modem to suppress them
  while the screen is off (Android does). None of this is on the phone's
  normal path: it does not auto-suspend by design
  (`diting-always-online.service`, `docs/ALWAYS-ONLINE.md`), and the owner
  confirmed on 2026-11-26 that that is intended. One manual deep suspend
  that day, on USB charge, with the three `qcom-battmgr` supplies no longer
  wakeup sources: 25.05 s of sleep, ended by something other than the RTC
  alarm set for 60 s. The waker was not looked for.
- **Phone stayed awake after a wake-up from sleep** (fixed in device package
  0.7.15, kernel r45): the ADSP charger firmware sends a Xiaomi status
  message (opcode 0x50) every 480 s, and it ends deep sleep (5 of 5 traced
  wakes on 2026-10-15). GNOME turns the screen on for a minute after every
  resume and then does not suspend again until the phone is used, so the
  phone stayed awake with the screen off for 20-80 minutes and got warm.
  `diting-resuspend` (a system-sleep hook and service) suspends again 20 s
  after a resume unless a key was pressed, any input device reported an
  event, something inhibits sleep, or a call is active. Switch it off with
  `sudo systemctl mask diting-resuspend.service`. Kernel patch 0093 drops
  the 0x50 message (it used to complete the ack of a pending battery
  request); the message still wakes the phone.
- **Screen lit up at every automatic wake-up** (fixed in device package
  0.7.16 + patched phosh, `make phosh`): phosh and gnome-settings-daemon
  turned the screen on at every resume, so it lit up for 20 s every
  8 minutes. The system-sleep hook now creates `/run/diting-resuspend.dark`
  when no power or volume key was pressed during suspend; the patched phosh
  then keeps the outputs off. The power key, an incoming call or a
  notification that wakes the screen still turn it on. Input while the
  screen stays off (a touch in a pocket) no longer keeps the phone awake.
  DEVICE-TESTED 2026-10-21 with an RTC wake: screen off (DSI `dpms` Off)
  for the whole wake, suspended again after 21 s. Power-key wake from sleep
  not yet owner-tested. An archive phosh with a higher version replaces the
  patched one; then the screen lights up again.
- **SLPI handover messages**: `qcom_q6v5_pas 2400000.remoteproc: Handover
  signaled, but it already happened` floods the log (rate-limited) in bursts
  of about 90 s at ~8/s, after boot and after some resumes: the sensor DSP
  toggles its smp2p ready and handover bits. Sensors keep working. The
  smp2p sleep state entry that the vendor kernel exports to the SLPI (r46,
  0095/0096) does not stop it; cause unknown.
- **Fixed in device package 0.7.10/0.7.11**: calls had no audio since kernel
  r30 (libadsprpc used the system dma-buf heap; the audio PD now uses the
  fastrpc allocator); mobile data was lost after every suspend (ModemManager
  removed the modem; now quick suspend/resume) and ModemManager 1.25.95
  crashed re-creating the data link after a resume (local rebuild with the
  upstream fix, pinned; the phone ran two days without that fix in November
  2026, see the 2026-11-24 section at the end). Kernel r40 (patch 0085): the
  fastrpc driver lost
  one DSP request per suspend (the freezer interrupted adsprpcd's listener
  wait), so the first voice-graph opens after N suspends failed and calls
  had no audio; owner-tested call after 3 suspends with audio. Kernel r41
  (patch 0086): the bottom speaker was silent whenever the speaker
  protection firmware ran (its second receive slot repeated its own channel;
  the vendor layout gives RX2 the other channel).
- **Wi-Fi 5 GHz** (fixed in r42 / firmware 0.9.4): ath11k used the generic
  board-id-255 entry of Ubuntu's board-2.bin (another design's RF setup):
  no 5 GHz networks at all and one stream on 2.4 GHz. Ubuntu's default
  WCN6855 firmware rejects the phone's own board data. Kernel r42 (patch
  0087) loads WCN6855 firmware from the nfa765 directory on this phone;
  firmware-xiaomi-diting puts the firmware Android uses there under
  updates/ (amss20.bin, WLAN.HSP.2.0.c2, with m3.bin), plus a board-2.bin
  with bd_l12gl.elf (the file Android loads) and this phone's MAC from
  persist (the Xiaomi board data has none). Without the firmware package
  Ubuntu's nfa765 firmware runs with the generic board data (2.4 GHz).
  After a clean boot: both chains receive (5 GHz [-57, -66] dBm), TX
  866 Mbit/s, no lost frames; owner speed test on the vendor firmware
  (before the reloads) over 400 Mbit/s.
  Repeated ath11k module reloads (about 20 in one boot, with PCIe AER
  timeouts) left the chip with one deaf chain per band and 80-90 %
  transmit failures until a reboot: do not judge Wi-Fi after reloads.
- **Wi-Fi band choice** (device pkg 0.7.13): wpa_supplicant roams within a
  network only to a stronger access point (background scan every 300 s
  while the signal is above -65 dBm), so after a room with weak 5 GHz the
  phone stayed on 2.4 GHz next to the router. diting-wifi-band-steer scans
  once a minute while on 2.4 GHz and roams to the same network's 5/6 GHz
  access point at -72 dBm or better; device-tested 2.4 GHz -> 5180 MHz,
  link 1921/1441 Mbit/s (160 MHz, 2 streams).
- **Wi-Fi throughput** (r43, patch 0089): all ath11k data path interrupts
  arrive on CPU 0 (multiplexed PCIe MSI, affinity fixed), so receive
  processing ran in softirq on that little core (ksoftirqd/0 91 %) and
  TCP downloads reached about 210 Mbit/s on a 1921 Mbit/s link (657 with
  Wi-Fi power save off). Threaded NAPI moves the rings to kthreads on
  other cores: 888 Mbit/s from a gigabit-wired PC with power save on
  (857 off), i.e. the wired side's limit.
- **Speaker protection** runs: the CS35L41 protection firmware (Cirrus CSPL)
  with this unit's factory calibration from persist/audio/crus_calr.bin
  (top 5.90 ohm, bottom 7.12 ohm), set up by diting-speaker-protection at
  boot (needs firmware-xiaomi-diting >= 0.7.3, otherwise the plain ASP path).
  With it running, media plays at Android's level (digital 0 dB, analog gain
  17; owner listening test: correct); without calibration the speakers stay
  6 dB lower at minimum analog gain.
- **phoc mode switching** needs the patched phoc (`make phoc`, pinned); with
  Ubuntu's phoc every refresh-rate change reverts to 60 Hz.
- **Shutdown**: `gnome-session-init-worker` ignores SIGTERM; session scopes get a
  5 s stop timeout (device package) instead of the 90 s default.
- `disp_cc_mdss_mdp_clk_src: rcg didn't update its configuration` warning at
  boot (harmless so far).
- `systemd-networkd` runs next to NetworkManager.

### Video encoding: enabled since 0119–0129, with limits (2026-11-26)

The iris encoder is registered again (driver-fix with patches 0119–0129, on
the phone since 2026-11-26 18:18): `/dev/video1`, "Iris Encoder", a V4L2
stateful encoder - `h264_v4l2m2m` and `hevc_v4l2m2m` in ffmpeg. GStreamer
has no element for it, and there is no VA-API encoder. What the encoder did
in r35, and what ended it, is under "Fixed" below. Read on the phone: H.264
and HEVC at 720p30, 1080p30, 1080p60 and 4K30, every frame sent is in the
stream (decoded in software and compared with the source: PSNR 39-46 dB);
two encoders at once; an encoder next to a hardware decoder, the decoder's
output unchanged; CBR at 4 Mbit/s, 300 frames; 1800 frames in one go. The
kernel log had nothing new through all of it. Limits:

- **The stock ffmpeg crashes at random when the frame height is not a
  multiple of 32.** The encoder negotiates its input buffer for the padded
  height (736 lines for 720) and the stock ffmpeg copies that many rows from
  the frame it is given, past its end: whether that faults depends on where
  the frame was allocated. On 2026-11-26, 10 of 15 runs at 720p, 1080p and
  960x540 ended with SIGSEGV (exit 139) before the first frame, the other 5
  encoded the same input correctly; the kernel log says nothing. With the
  input padded first (`-vf pad=1280:736` for 720p) every run passes, and the
  stream then has the padded height. **Read from the coredump that
  evening**: `avcodec_send_frame()` → the encoder handing the frame to the
  driver → `memcpy`, faulting on a read at the first byte past the frame's
  buffer, into a V4L2 buffer of 1280x736 (the mapping of `/dev/video1`).
  4 of 10 runs that evening crashed, 0 of 6 with the input padded. The
  driver reporting the aligned size is upstream's own behaviour
  (`iris_venc_s_fmt()`, the same on the tablet). **The fix is in the
  tree**: `packages/ffmpeg-diting` carries liuqin-linux-kit's patch 0001
  (the visible rows only, the chroma after the padded luma); its static
  build, on 2026-11-26 still a small static one, went through 80 of 80
  encodes with the input not padded (`ci/FFMPEG.md`). Rootfs images built from 2026-11-27 on have it in
  `/usr/local/bin`, ahead of the archive's on every PATH; until such an
  image is flashed, pad the input for the stock one.
- **The stock ffmpeg loses the last frames of a stream at times**: 2 to 5
  of 60 in 7 of 80 runs on 2026-11-26, 2 to 13 of 900 in longer runs,
  with nothing in the kernel log. Its encoder wrapper gives up at the
  drain while packets still hold the capture buffers; the kit's patch 0003
  (in `packages/ffmpeg-diting`) is for that - 0 of 80 there.
- No forced keyframes: the driver offers no control for it (upstream 7.3
  has one).
- The HEVC level is not constrained by the driver (H.264's is, by 0128).

### Browser video decoding (VA-API over V4L2)

Firefox and Chromium decode H.264, HEVC and VP9 on the iris decoder through
the `libva-v4l2-stateful` package (patched VA-API driver, also installed as
`msm_drv_video.so`, so no `LIBVA_DRIVER_NAME` is needed). Limits:

- **Snap Chromium** cannot read host libraries. A systemd user service
  (`diting-chromium-vaapi`) copies the driver into
  `~/snap/chromium/common/dri` at login and writes `~/.chromium-browser.init`
  (VA-API feature flags) if there is none. After a package upgrade the copy
  is refreshed at the next login, or by running `diting-chromium-vaapi`.
- **The driver opens only `/dev/video0` or `/dev/video-dec0`**
  (`v4l2_open_device()` in upstream `src/v4l2-backend.c`). The iris decoder
  is `/dev/video0` only when it registers before the cameras, a race at every
  boot: on 2026-11-27 (the image of 40ae371, cameras first) it was
  `/dev/video4`, `vainfo` said `No V4L2 M2M decoder found`, and Chromium
  decoded in software although it had loaded the driver and could open the
  decoder's node from inside the snap. The package installs
  `/usr/lib/udev/rules.d/70-diting-iris-decoder.rules`, which symlinks
  `video-dec0` to the decoder whatever its number (`make verify` checks that
  it is in the image). With the rule in place `vainfo` lists the seven
  profiles again, and Chromium, restarted, held the decoder open while a
  video played.
- **Chromium path**: Chromium never calls `vaSyncSurface`, so the driver
  finishes each picture in `vaEndPicture`, and decodes straight into
  Chromium's buffers with only one CAPTURE buffer queued at a time (the
  firmware returns empty buffers for hidden VP9 frames out of order).
  Decoding is serialised per frame; 4K VP9 plays smoothly.
- **10-bit** (HEVC Main10, VP9 profile 2) is advertised but only NV12
  output is implemented: untested and expected to fail.
- No AV1: the decoder lists only H.264, HEVC and VP9 (`VIDIOC_ENUM_FMT`).
- Kernel r38 or later is required: earlier iris read past its timestamp
  metadata (0084) and could end decoding with a spurious EOS.

### Reboot can hang after the video codec was used

Several reboots hung at the end of `systemd-shutdown` after iris sessions;
the owner had to hold the power key. Removing the iris module while the
core is initialised deadlocks (`iris_core_deinit` holds `core->lock` and
calls `disable_irq()`, while the IRQ thread waits for that lock); the
shutdown hang may be the same path. Not yet confirmed; the deadlock itself
is, see the next entry.

Since 0121 (driver-fix, 2026-11-26) the IRQs are drained before the
power-off and outside `core->lock`, which is this deadlock. The module was
not removed again to try it (`qcom_iris` is not unloaded and reloaded on
this phone, see below), and no shutdown has been watched for the hang
since.

### The iris error path deadlocks when the firmware watchdog fires (2026-11-26; the IRQ wait fixed by 0121, read again that evening)

Reproduced on the decode path, on formal-7.2.10-52 with the r54 DTB. Twelve
VA-API decoders were started at once on the one iris decoder (to read which
OPP the core runs at; one at a time is what the tests before it used, and
nothing in between was tried). The firmware's CPU watchdog fired
(`received watchdog interrupt`, `cpu watchdog error received`, `system
error of type 0x5000001`); the sessions started after it got `system error
of type 0x5000003`, then `core init failed`, a WARNING in
`vb2_start_streaming`, and `Unbalanced enable for IRQ 218` from `iris_open()`
→ `iris_core_init()` → `iris_vpu_power_on()`.

From then on three parties wait for each other and nothing but a reboot ends
it (kernel stacks of that boot, uptime 27661 s):

- `kworker/0:0+events` runs `iris_sys_error_handler()`:
  `iris_core_deinit()` → `iris_vpu_power_off()` → `disable_irq()` →
  `__synchronize_irq()`, holding `core->lock`;
- `irq/218-iris` sits in `iris_hfi_isr_handler()`, waiting for `core->lock`;
- every process that then closes a session (`VIDIOC_STREAMOFF` →
  `iris_session_streamoff()` → `iris_hfi_gen2_session_stop()` →
  `iris_hfi_queue_cmd_write()`, in the runtime PM resume of the device) goes
  to D state and stays there; eight `ffmpeg` were left like that, `SIGKILL`
  included.

Hardware decoding is gone for that boot; the rest of the system was not
affected (USB, SSH, display). This is the deadlock the entry above suspects
for the shutdown hang, on a path decode alone reaches. The fix belongs in
`iris_core_deinit()` and the ISR: not disabling the IRQ under `core->lock`,
and failing opens and session stops with an error once the core is in the
error state, instead of resuming the device. Until then, few decode sessions
at a time, and a reboot when `dmesg` shows the watchdog lines.

**Read again on 2026-11-26 in the evening**, on driver-fix with 0119–0129
(0121 is the fix this entry asks for; 0119, 0120 and 0123 change the
power-off around it): twelve VA-API decoders at once again, this time on a
4K clip. The firmware did not reach its watchdog. The driver let eight
sessions through (the frame limit of 0123), refused four
(`current session not supported(-12)`; ffmpeg decoded those four in
software), and the firmware answered the eight with `system error of type
0x5000003` - `HFI_SYS_ERROR_FATAL` in the vendor's `hfi_property.h`. No
`core init failed`, no `Unbalanced enable`, no process in D state: the
system-error worker ran to the end and the core went back to suspended.
Decoding (VA-API and ffmpeg's `hevc_v4l2m2m`, both equal to a software
decode) and encoding worked in the same boot afterwards. What this shows is
that a firmware system error no longer locks the driver. It does not show
that the watchdog path is fixed: that path was not reached again, and the
clip of the morning is not on record, so the two runs are not the same
load.

What the overload still leaves. None of it is reached with a few sessions
at a time:

- A WARNING at `videobuf2-core.c:1821` in `vb2_start_streaming`: on a failed
  start the driver hands the queued buffers back as `STATE_ERROR`, where vb2
  asks for `STATE_QUEUED`. The same line in the morning's run; upstream
  reads the same in 7.3.4.
- One SMMU context fault from the video core (`SID=0x2184`,
  `iova=0x07e00000`, a translation fault) while the sessions failed: an
  address that was not mapped at that moment. None in the 1085 s before,
  none after.
- Two of the eight ffmpeg processes spun in user space after the decoder
  error (one frame thread at 100 % CPU) and ignored SIGTERM; SIGKILL ends
  them. Nothing stays in the kernel.
- The driver's limit (eight 4K sessions) is above what the firmware serves
  at that load. `iris_check_core_mbps()` exists for the load and is not
  called by the admission check.

The first and the last of these are gone since (0133, 0134), and the
recovery path had a hole that this load showed: the next entry.

### Sessions the firmware serves, and the hole the recovery had: 0130–0135 (2026-11-26)

On the phone since 2026-11-26 23:05 as the module alone
(`updates/qcom-iris.ko`, `13c30150b3afe8f5…`): the kernel image, its
configuration and the DTB are those of 0119–0129, byte for byte. What
changed, with what was read before and after:

- **Admission by frame size (0134).** The driver's limit was the vendor's
  MAX_MBPF (276480 macroblocks a frame: eight sessions of 4K), and
  decoders start with a frame rate the load check cannot see, so every
  session was admitted. Read with VA-API decoders on the kernel before:
  four sessions of 4K decode to their end; the fifth, and more, ended in
  the firmware's fatal system error in nine of nine runs, whatever the
  pacing, the spacing or the stream (intra-only, P-frames); of the mixes
  just above the figure, one of four passed. The limit is now what passed,
  130560 macroblocks a frame. Read since, three times: the fifth decoder
  of 4K is refused at once (`current session not supported(-12)`; ffmpeg
  decodes that one in software) and the four others are not disturbed.
- **The session count at open() (0130, upstream `397ebadcbc`; 0131,
  local, frees the controls of the instance that is refused).** Sixteen
  sessions, as the firmware has: the 17th `open()` fails with `EBUSY`, in
  0 ms. One process opening `/dev/video0` twenty times gets sixteen;
  after an overload the node opens again the same way.
- **The queues of an instance in error (0133, local).** The two videobuf2
  warnings above are gone: a buffer that arrives at an instance in the
  error state comes back as queued, as `start_streaming()` hands back the
  rest, and the session takes a buffer before it puts it on the ready
  queue. The queues are not marked in error on purpose (see the reset
  below): a process with buffers queued learns of the error when it
  closes the session. Read: fifteen 1080p decoders at once, when they end
  in the firmware's error, are all gone in 2–6 s without a signal, no D
  state, no warning line, and the next decode is correct.
- **0132 (upstream `4524809316`)** cancels the system-error work when the
  driver is removed. Not exercised: the module is not removed on this
  phone.
- **The hole in the recovery (0135, local).** `iris_core_init()` returns
  `-EINVAL` when the core is in `IRIS_CORE_ERROR`, and went on to the
  label that writes `IRIS_CORE_DEINIT` - over a core that is still
  powered on, with its IRQ enabled and its firmware loaded. The worker
  that recovers the core starts with `iris_core_deinit()`, which powers
  off unless the state is `IRIS_CORE_DEINIT`. So one `open()` in the
  window between the firmware's error and that worker (10 ms and more)
  made it skip the power-off, and the `iris_core_init()` that followed
  powered on a core that was on. Upstream has it to this day (7.2.10 and
  master of 2026-11-16 read the same). Now the state is left as it is:
  the `open()` gets its `-EINVAL` and the worker powers the core off
  first. Where nothing had scheduled the worker (the firmware answering
  the system init with an error, or not within a second), the refused
  `open()` schedules it.

**The reset, and what it was.** A first build of this batch marked the
queues of an instance in error as well (`vb2_queue_error()` from
`iris_inst_change_state()`). With it, seventeen 1080p decoders started
half a second apart followed by twenty opens **reset the SoC twice**
(21:33, and the replay with the kernel log captured live). The log of the
replay, against the code: the firmware's system error at 422.30 s; the
recovery; a second system error 105 ms after the first; 8 ms later the
`core init failed` of an `open()` - refused, and on that path the state
written to `IRIS_CORE_DEINIT` while the core was on; the next run of the
worker, 9.6 ms after that line, `Unbalanced enable for IRQ 219` from
`iris_vpu_power_on()`: the power-off's `disable_irq()` had not run. The
firmware watchdog fired 2.2 s later, and the twenty opens that followed
reset the SoC. The `Unbalanced enable for IRQ 218` from `iris_open()`
read the same morning fits the same path. The marking itself did no
harm: it only made an `open()` in that window more likely. The phone was
put back on the module of 0119–0129 in between, then on this batch
without the marking (22:04), which has the hole as well: the same
sequence then ran three times without reaching the window, as it had
twice with the marking. With 0135 the window was forced: an
`open()` and `close()` every 2 ms on the decoder node around the same
overload, three rounds, 27 to 29 thousand opens each; 53 to 75 per round
fell in the window and were refused (196 `core init failed` in the log),
and there was no `Unbalanced enable`, no watchdog and no reset; the
decode after each round was correct.

What the overload still leaves, with 0130–0135:

- Fifteen to seventeen sessions of 1080p are above what the firmware
  serves at times, and a limit on the frame size cannot tell them apart:
  sixteen started together failed twice of twice, fifteen failed in three
  of four runs, seventeen started half a second apart failed in three of
  six, while thirteen, fourteen and sixteen started a second apart
  passed. They end in the firmware's error (`0x5000003`), each time with
  one SMMU context fault from the video core (`SID=0x2184`), and while
  the sessions still submit, the driver recovers about once a second (up
  to eleven `received system error` lines in four seconds), until they
  are gone. Nothing stays in the kernel.

### The video decoder on a cold start: frames differ, and a reset after a reload by hand (2026-11-26, ON HOLD)

**On hold by the owner's decision**: video decoding stays as it is until the
other drivers are in order. Nothing below is being worked on, and two things
are not to be done on the phone meanwhile: decode experiments, and unloading
`qcom_iris` to load it again.

Read on driver-fix batch 1 (patches 0001–0115), the kernel the phone runs
since 2026-11-26. The driver, its firmware and the device tree are what the
phone ran before; the nine new patches touch none of them.

- **The first decodes of a boot are not bit-exact.** Through ffmpeg with
  VA-API (`libva-v4l2-stateful`), against a software decode of the same
  clip: the first clip after boot (x264 medium, 60 frames) differed in all
  60 frames, the second (x264 veryfast, 60 frames) in 50. A few minutes
  later, with the decoder in use in between, the same two clips gave 60 of 60
  and 150 of 150 identical frames, and the comparison of
  `docs/liuqin-study/VIDEO_DECODE.md` (GStreamer V4L2 against software) gave
  the result recorded there: H.264 and HEVC 8- and 10-bit 90 of 90, VP9 as
  before. So the hardware is right once warm; what the first sessions after
  boot do was not looked at. Whether the old kernel did the same was never
  read: the tests of 2026-11-25 all ran hours after boot.
- **A reload by hand reset the phone.** To reach a cold decoder without a
  reboot, `qcom_iris` was unloaded and loaded again (`modprobe -r qcom_iris`,
  `modprobe qcom_iris`, no user of `/dev/video0` at the time) and a decode
  was started at once. The connection dropped in that moment. The journal of
  that boot ends with nothing after the `sudo` line that started the test:
  no shutdown, no kernel message; `/sys/fs/pstore` is empty; the phone came
  back with the same boot reason fields as after a normal reboot
  (`bootinfo.pureason=0x80001 bootinfo.pdreason=0x2`) and with the same
  kernel and modules. Whether an unload and reload of `qcom_iris` is
  supported at all — firmware, reserved memory, the protection domains —
  was not checked.

What it costs: nothing in normal use so far. Two complete boots with this
kernel, no process in D state, no decoder error in either log. The sample
clips, all under `/var/tmp`, were removed. pstore gave nothing on this reset:
after such an end, do not count on a console log.

### Boot: ten SMMU context faults in the log, at least 3,232 in all (2026-11-26)

Each of the last sixteen boots in the journal logs ten `Unhandled context
fault` lines from the display controller (`mdss`: `SID=0x2800` and `0x2c00`
are one stream, its mask is `0x402`; `cb=9`; IOVAs from `0xb8000980` up) in
the first seconds, known as "the ten at boot". They are the first ten: the
line is limited to ten per 5 s, and when the next fault of that SMMU
arrived, 1083 s later in the boot of 2026-11-26 18:18, the kernel reported
`arm_smmu_context_fault: 3222 callbacks suppressed` - that many more were
dropped in the same burst. The display driver probing while the bootloader's
splash is still being scanned out is the likely reason; not looked at.
Harmless so far, and the same on every boot of this kernel line.

### One boot with `qcom-battmgr-usb` not answering `voltage_now` once (2026-11-26 18:18; seen once)

`power_supply qcom-battmgr-usb: driver failed to report 'voltage_now'
property: -110` at 11.68 s of the boot of driver-fix batch 4, between the
`hexagonrpcd` lines that say the ADSP's `sns_registry` is not there yet.
None of the seven boots before it has the line, and that batch does not
touch the battery code (`qcom_battmgr.ko` is the one of batch 1). The
property read 5.23 V an hour later. Most likely a read that reached the
driver before the ADSP's battery manager answered. Seen once: watched, not
chased.

### One boot with the greeter's user manager stopping past its timeout (2026-11-26 22:04; seen once as failed)

`user@100.service`, the user manager of greetd's greeter (`_greetd`),
failed with `Result: timeout` 44 s into the boot: its stop was held by
`obex.service` ("User job obex.service/stop running"), and systemd killed
the manager. The desktop session was not affected; `systemctl
is-system-running` said `degraded` until the next boot. In the two boots
before, the same manager logged `xdg-document-portal.service: Failed to
kill control group` and stopped all the same. The video driver is not in
it: the boot after, on the module with 0135, came up `running`. Watched.

### Memory: 1.6 GiB of the 12 GB is reserved before Linux counts (2026-11-26; 628 MiB of it optional)

`MemTotal` is 10,614,296 kB on the 12 GB phone. 12,301,312 kB reach the
kernel (about 275 MiB are held before that), and 1.63 GiB is reserved at
boot: the device tree's reserved-memory, about 1.36 GiB (the modem 306
MiB, other firmware about 250 MiB, two regions for virtual machines about
155 MiB, `splash_mem` 43 MiB, and three that upstream's `sm8450.dtsi` has
and the stock device trees of this phone do not: `mte_mem` 512 MiB,
`trusted_apps_mem` 57 MiB, `trusted_apps_ext_mem` 59 MiB - 628 MiB), CMA
44 MiB, swiotlb 64 MiB, the kernel about 170 MiB. Upstream removed the
three in 7.3.x ("not present on downstream device trees and only take
memory away from the AP"). `kernel/patches-experimental/0136-…` does the
same on 7.2.10; `release/driver-fix-batch5/optional-0136-reserved-memory/`
has a `vendor_boot.img` with it, built and **not flashed**: it is a write
to `vendor_boot_a`, so it waits for the owner.

### Char-device use-after-free at boot (oops in `kobj_lookup`)

Seen twice on r35/r36: `v4l_id` (udev) oopses in `chrdev_open` ->
`kobj_lookup` at virtual address `0x2400000000`/`0x2400000008`, i.e. a
stale entry in the char-device map from a driver that freed its cdev
without unregistering it. With `kernel.panic=0` the boot hangs. Driver not
identified yet. A KASAN build (generic, inline) boots too slowly for the
default `deferred_probe_timeout`: GPU SMMU and CCI probes time out and
the boot hangs in PCIe probing at ~20 s, so the KASAN run needs a longer
timeout. That KASAN run did find a global out-of-bounds read in
`qcom_spmi_temp_alarm` (fixed by patch 0082).

### Compute DSP (CDSP) and FastRPC

The CDSP runs since r46 (0094, firmware 0.9.5 with `cdsp.mbn` and the
vendor's `dsp/cdsp` libraries, including `fastrpc_shell_unsigned_3`).
libcdsprpc finds the process shells through
`/usr/share/qcom/conf.d/xiaomi-diting.yaml` (device package 0.7.17), and the
logged-in user can open `/dev/fastrpc-cdsp` (udev `uaccess`).
DEVICE-TESTED 2026-10-21: Qualcomm's `fastrpc_test -d 3 -U 1 -a v68`
(calculator, multithreading, HAP memory) passes in an unsigned PD, 3 of 3
runs. Limits:

- **No dma-buf heap**: when libcdsprpc can open `/dev/dma_heap/system` it
  allocates its shared buffers there; those are CPU-cached and the fastrpc
  driver does no cache maintenance on them, so the DSP reads stale data and
  dynamic loading fails at random ("bad elf magic", "mmap hdrs failed",
  "lseek failed"). Users without access to the heap (the default; only root
  and the `fastrpc` group have it) get the driver's own buffers and work.
  Do not add users to the `fastrpc` group; run root clients with
  `InaccessiblePaths=/dev/dma_heap` like `diting-audiopd.service`.
- Only unsigned PDs: signed PDs would need Xiaomi's test signatures.
- Machine learning on the HTP (Qualcomm AI Engine Direct / QNN, Hexagon
  v69) not yet tried.

### Rare early-boot oops while fastrpc probes (seen once)

One boot oopsed at 6.8 s (`paging request at 0000002400000000`) while the
CDSP fastrpc context banks were probing; the call trace was lost. With
`kernel.panic=0` the phone then hangs; `/etc/sysctl.d/90-diting-panic.conf`
on the test phone now sets 10 s (applies only after systemd-sysctl).

## Fixed, kept here for context

- **The video encoder (0119–0129, 2026-11-26).** With the encoder enabled
  in r35, starting its raw input port hung the firmware and the next
  command reset the SoC, so r36 registered the decoder only. On Iris2 the
  encoder's ARP buffers belong in the secure non-pixel DMA context (SID
  `0x2184`, VMID 11 = `CP_NON_PIXEL`), with that context's page tables
  shared with the VMID through `qcom_scm_assign_mem`; the core also needs
  the vendor's reset and power-down sequence. liuqin-linux-kit had both on
  the same SoC. The eleven patches take its six and three upstream fixes
  (7.2.10 lacks them; 7.3.4 is not needed, the phone's firmware and device
  tree already have the secure context). `docs/liuqin-study/KERNEL_COMMITS.md`
  §8 lists them; the limits that remain are in "Video encoding" above.
- **A configuration change and the modules on the phone (2026-11-26).** The
  phone keeps the modules of its package; they fit a new kernel only while
  the configuration stays. With the filesystems switched on, two things went
  wrong in one boot. `btrfs.ko` of the package, compiled before fscrypt and
  fs-verity changed the layout of `struct inode`, oopsed in `open_ctree()`
  when a test mounted a btrfs image; the superblock it left behind held its
  lock, every later `sync()` waited forever, the phone got sluggish and the
  reboot had to be `sync -f /` and SysRq-b. Then Wi-Fi did not come up:
  `libarc4` had become built in, its file stayed, and `modprobe mac80211`
  stopped at the dependency `libarc4.ko` ("exports duplicate symbol").
  Since then btrfs, overlay, ubifs, cuse and NVMe are built in too, the files
  of the 19 modules that became built in were moved away, and the lists of
  the running build (`modules.builtin`) are on the phone. The procedure is in
  `ci/KERNEL.md` ("When the configuration changes").
- **ADSP services late or missing after boot** (device package 0.7.14):
  udev loaded `qcom_pd_mapper` in parallel with `qcom_q6v5_pas`; when the
  ADSP (started first, ~7 s) found no PD mapper it retried only after 50 s,
  300 s or not at all. Until then the battery read 0 % (`-EAGAIN`), charging
  was not reported, speaker protection failed and there was no sound card.
  `/etc/modprobe.d/diting-dsp.conf` now loads the PD mapper first: ADSP
  services at ~13 s, sound card and speaker protection at ~15 s.
- **GPU GMU resume** (0027): the A730v3 GMU needs up to 12 ms to leave reset;
  upstream waited 10 ms. Now 100 ms like downstream.
- **A/B retry counter**: `diting-boot-successful.service` marks the slot
  successful, else ABL marks it unbootable after 7 boots.
- **Mobile data** (0030–0043, firmware 0.6.0): IPA v5.1 from the XEC kernel.
  The ModemManager TUN placeholder port of device package 0.4.x is gone.

- **Waydroid** (2026-10-15): Android had no internet (kernel lacked policy
  routing; fixed in r44) and no shared storage (the MAINLINE vendor image
  declares an OMX codec service it does not ship, so MediaProvider hangs).
  Steps for users: `docs/WAYDROID.md`.

## Configuration the owner sets per phone (not packaged)

- Mobile data APN: a NetworkManager `gsm` connection, e.g.
  `nmcli c add type gsm ifname '*' con-name mobile gsm.apn <apn>`. Odido uses
  `smartsites.t-mobile`. Wi-Fi keeps the lower route metric. Give the
  connection `connection.autoconnect-retries 1` as well: NetworkManager
  starts the next activation 2 ms after a failed one (2026-11-24, below).
- Network mode: `/etc/diting/modem-mode`, e.g. `allowed="3g|4g|5g"` and
  `preferred="5g"`, is set on every boot (`diting-modem-setup` and
  `diting-modem-mode.service`). The desktop's mobile network settings do not
  survive a boot; without the file every technology is allowed (2026-11-24,
  below).
- Same file, for an LTE-only carrier such as China Telecom:
  `usage="data"` and `service_domain="ps-only"` (`diting-nas-pref` at boot;
  2026-11-25, below). Leave them out where 2G/3G calls and SMS must work.
- rmtfs runs read-only (`-r`): modem EFS changes do not persist, which is why
  `diting-modem-setup` re-applies the USIM session and RAT preference each boot.

## Public images

- Tested on one unit only (EEA, HyperOS OS3.0.5.0.VLFEUXM). Other
  HyperOS/MIUI versions give other firmware builds (ADSP, modem, ACDB); the
  audio topology and the IPA data were only checked against this one.
- The vendor partition carries a second main camera (Samsung HM6); units
  with it have no main camera.
- Bluetooth address: the QCA6490 reports the placeholder of the generic
  NVM (`00:00:00:00:5A:AD`) and the kernel starts it unconfigured unless
  it is given one. `diting-bt-address` derives a locally administered
  address from the factory Wi-Fi address in persist (the same after every
  reflash; the hashed machine id where there is none). Boot images built
  on the phone carry it in the device tree (`diting-bt-fixup` writes them
  on the first boot); server-built ones do not, and `diting-bt-setup`
  then sets it at runtime on every boot. For an address of your own:
  `/etc/diting/bt-address`. (Upstream's EEA unit was reported to run with
  the placeholder instead of starting unconfigured; not seen here, and
  `diting-bt-setup` leaves such a controller alone.)
- The default PIN 147147 is public; users must change it (`passwd`). sudo
  asks for it (owner images: no password, key-only SSH).
- The full image has not been flashed on a phone by the owner; its parts
  (kernel, packages, firmware extraction) were tested separately.

## Risks / not verified

- eUSB2 repeater: upstream `nxp,ptn3222` driver does not apply the vendor tuning
  values.
- UFS limited to the SM8450 300 MHz clock table (vendor: 850 MHz); performance only.
- Regulator supply parents (`vdd-*-supply`) are not described. PM8350B L1 and
  PMR735B regulators not described.
- `fw_devlink.sync_state=timeout` is on the cmdline because gcc/gpucc wait for
  the GMU forever otherwise.
- GPU identity: the A730v3 (chip id 0x07030002) runs with the upstream A730
  (0x07030001) catalog entry, which Mesa knows as FD730.
- IPA: the XEC v5.1 data was written for SM8450 (OnePlus 10 Pro); SM8475 values
  were only cross-checked against the vendor DT, not against vendor `ipa3`
  resource tables. Throughput, tethering and IPv6 untested.
- Build host: GCC crashes with THP on the edge host kernel; worked around with
  `nothp` (BUILD.md).
- CoreSight/QDSS nodes inherited from `sm8450.dtsi` stay blacklisted
  (`/etc/modprobe.d/diting-bringup.conf`).

## CN units: display pipeline wedges on the idle dim (2026-11-21)

On a CN unit (OS3.0.3.0.VLFCNXM firmware) every idle dim froze the UI and
blacked the screen: the DSI brightness write (DCS 0x51) times out
(`dsi_cmds2buf_tx: cmd dma tx failed`), after which DPU commits never
finish (`wait for commit done returned -22/-110`, `ctl start interrupt
wait failed`, ~450 errors per wedge) and the panel does not come back
until reboot. The EEA unit of the original author does not show this.
Workaround (shipped as a note, not packaged): disable idle blanking —

    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.desktop.screensaver idle-activation-enabled false

A proper fix needs panel/driver work on the dim path (patch 0015 territory).

## The PMK8350 RTC: the AP cannot write it, and reading it at boot put the clock in 1970 (2026-11-21; the second half found and fixed 2026-11-26)

The SPMI PMIC arbiter rejects every AP write to the RTC registers
("disallowed SPMI write to sid=0, addr=0x61xx"): allow-set-time makes
rtc_set_time reachable, and the kernel's NTP sync_hw_clock worker then
retries the rejected write ~47 times per second, forever (12k+ denied
writes per boot). The RTC is read-only for the AP - the Rubik Pi 3
precedent does not transfer. Keep the RTC read-only (patch 0028 as
upstream); time persistence is systemd's timesync clock file plus NTP
after any unclean poweroff.

The other half, found on 2026-11-26: reading it is as wrong as writing it.
The RTC counts from 1970-01-01 at every PMIC reset. Its driver is a module
(`rtc-pm8xxx.ko`, loaded at 5 s), and `drivers/rtc/class.c` sets the system
clock from the device named in `CONFIG_RTC_HCTOSYS_DEVICE` when that device
registers, whatever the clock is. So systemd restored
`/var/lib/systemd/timesync/clock` at 4 s, and at 5.38 s the clock went back
to 1970 and stayed there until the first NTP reply — 245 s after boot in
the boot of 08:29 that day. In that window certificates fail, new files get
1970 timestamps, and the journal is out of order.

`kernel/config/diting.config` now has `# CONFIG_RTC_HCTOSYS is not set`
(driver-fix). DEVICE-TESTED 2026-11-26 09:03: the journal of the boot after
the change has systemd's "System time advanced" line at 3.4 s, no
"setting system clock" line, and no entry stamped before 2026; the clock
was 9 s behind until NTP, instead of 56 years. The RTC is still registered
as rtc0, so wake alarms are as before.

## CN units: no audio - the ADSP's SPF never answers (2026-11-21, RESOLVED 2026-11-22)

> **Resolved 2026-11-22:** the SPF never initialized because the DT's
> `qcom,vmids = <LPASS ADSP_HEAP>` on the fastrpc node made the kernel
> `qcom_scm_assign_mem()` the audio PD's 12 MiB remote-heap pool away
> from HLOS; subsequent coherent allocations from that pool aborted in
> `dcache_clean_poc()` (synchronous external abort, seen in dmesg with
> PID adsprpcd) and the audio PD's heap stayed half-broken. Removing
> `qcom,vmids` (patch 0045) fixed it; also required: `alsa-ucm-conf`
> installed (UCM2 resolution) and the UCM EnableSequence switches.
> Speaker playback verified. Full story: AUDIO-SPF.md, "RESOLUTION".

On the CN unit (OS3.3.3.0.VLFCNXM-extracted firmware) there is no sound at
all: every playback open fails and WirePlumber only creates a dummy sink.

    qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode

0x01001021 is APM_CMD_GET_SPF_STATE: at boot (13 s, before any audio
service) the q6apm driver's probe handshake with the ADSP's audio
framework times out, and a manual re-bind of the APM device first logs
"GPR: Port(1) is not registered" - the CN ADSP firmware's SPF never
registers its GPR port with the kernel. Every graph operation then fails
(FE opens return EINVAL, the ALSA card exposes no profiles).

Excluded with evidence: the CN voice topology (same timeout with the
plain device-package topology), missing components (cs35l41 x2 with DSP
firmware, wcd938x, all four lpass macros probe), the 1972 boot clock
(same timeout after a time-correct ADSP restart), the persist speaker
calibration (present on the real unit, protection DSP runs with
calibrated R), failed services (none) and userspace holders (none).

Next steps when picking this up:
- Establish whether audio ever worked on any CN boot (bisects a kernel
  regression against a firmware difference; the r46->r50 patches are
  log-level only and the config sweep touches nothing audio-related).
- Decisive test: extract the EEA firmware_mnt's adsp image from an EEA
  fastboot ROM and run it with the CN extraction for everything else.

## UFS controller wedges after SoC-level crash loops (2026-11-23, RESOLVED same day)

After a day of iris-encoder experiments killed the SoC repeatedly
(watchdog resets), the phone stopped booting to a usable system: the
kernel and initramfs came up, but the rootfs never mounted — black
screen, no USB network.

Symptoms (visible only through the `diting.debug=usb` initramfs shell):

- `ufshcd_check_errors: saved_err 0x4 saved_uic_err 0x4` error storm,
  SCSI commands fail with hostbyte=0x07, err handler loops forever.
- Raw single-sector reads at the start of sda37 succeed; reads further
  into the partition HANG. `mount` fails with I/O error.
- Driver-level `unbind`/`bind` of ufshcd-qcom restores short reads
  briefly — not a fix.

Root cause: UFS controller/link state machine left wedged by the crash
loop. Every reboot of the day (fastboot, watchdog, `reboot -f`) is a
WARM reset — the UFS power domain never drops, so the wedge survives
all of them.

The fix — a true power cycle:

1. Boot the debug image (`DITING_ROOT_CMDLINE="diting.debug=usb"`),
   wait for the `cu.usbmodem*` serial node on the Mac.
2. If the shell is stuck, force-reset (long-press power) and retry.
3. Send `poweroff -f` over the serial shell (skip sync — the point is
   to cut power, not to touch the broken storage).
4. Wait 30 s+, power on cold.

After the cold boot: zero ufshcd errors, rootfs mounts, system is
normal. No reflash was needed; the filesystem survived.

Discipline for future encoder experiments: every fw-crash session has
a nonzero chance of wedging UFS this way. End such a session with a
deliberate `poweroff` + cold boot before trusting the phone again. If
a full reflash is ever wanted anyway, a complete r51 owner set is kept
at `release/r51-images/` on the Mac (boot, vendor_boot, sparse rootfs).

## Kernels after r51 black-screened at boot: initramfs lost e2fsck (2026-11-23, RESOLVED)

Every -52-era boot image hung before the rootfs came up (PID 1 stuck in
do_wait inside the initramfs, black screen, no SSH), while the r51 images
booted reliably. The kernel and DT were exonerated by diffing the
decompiled DTBs (only camera nodes differ). The real difference was the
RAMDISK: builds after r51 had lost /usr/sbin/e2fsck, fsck and logsave.

Mechanism: the root fstab entry is `LABEL=diting-root` (fsck pass 1),
and the initramfs-tools fsck hook resolves that device on the BUILD
SERVER to identify the filesystem type. When a diting-root labelled
image happens to be attached during the build, the hook works; without
one (the normal case since Nov 22) it silently skips, the initramfs
ships without fsck binaries, and the boot waits forever at the root
fsck step. A build-environment flake that looked like a kernel
regression.

Fix (deterministic): `FSTYPE=ext4` in the device package's
initramfs-tools conf.d, so the hook never needs to resolve the device.
The hot-fixed work/rootfs and the committed package source both carry
it; any fresh `make rootfs` picks it up automatically.

Rescue tooling for a hung boot: `diting.debug=usb` on the cmdline gives
a root shell on the USB ACM serial (see scripts/serial-fsck.py —
e2fsck over serial; the same channel also carries module/file pushes
and poweroff for cold reboots).

## ModemManager segfaulted on every failed dial: the phone ran a build without the netlink fix (2026-11-24, RESOLVED same day)

For as long as the network did not accept dials, ModemManager died with
SIGSEGV every few minutes: 12 times in 75 minutes that evening. systemd
restarted it each time (about 30 s without a modem, then the next dial),
so it showed as "mobile data dies intermittently" and kept the redial
watchdog busy.

Four cores (systemd-coredump) show the same crash: PC 0x30, the return
address in `netlink_messages_cb`, and below it `netlink_setlink_ready`.
That is the netlink use-after-free of upstream 9317cbc4, which
`packages/modemmanager/0001` fixes: the completion handler called the
function pointer it read from the transaction it had just freed. It does
not need a suspend. When dials fail in quick succession (next section)
the netlink transactions of the `qmapmux0.0` link follow each other fast
enough for the freed memory to be reused; the old binary crashed within
five such links.

The phone did not have that fix. Its package said
`1.25.95-1ubuntu1diting2` and `dpkg -V` was clean, but it came from
`/tmp/mm2.deb` (installed 2026-11-22 07:40 going by the apt log), two
minutes before the build with both patches was written on the build
host. The disassembly of the call site tells the two apart: that binary
loads the pointer from the freed object, the build of this repository
loads it into a register before the free. It had 0002, the quick suspend
hooks, and not 0001.

Fix: `modemmanager` and `libmm-glib0` reinstalled from `output/debs/` on
the build host. The build is reproducible: the rebuild has the build-ids
of the November 22 packages. In its first 83 minutes the rebuilt binary
went through 72 dials and 17 link creations without a crash. The check
for any phone is in `packages/modemmanager/README.md`; the package
version cannot show it. Every ModemManager observation on this phone
between those two dates was made without the fix, whatever the version
said.

## NetworkManager dialled twelve times in a second after a failed connect (2026-11-24, MITIGATED)

With debug logging on NetworkManager, one activation is up to three
dials: `modem-broadband` tries ip type `ipv4v6`, then `ipv4`, then `ipv6`.
When all three fail, the device goes to failed and the policy
auto-activates the same connection again 2 ms later (the errors, `cm
error: unknown` and `pdn-ipv4-call-throttled`, are "unmapped": the
failure reason is unknown, so nothing holds the connection back). With
the default of four tries that is 12 dials in under a second, each
creating and deleting a `qmapmux0.0` link and asking the network for a
PDN connection. Every failed dial thus became twelve, which prolongs the
modem's PDN throttle, and it gave the use-after-free above its window.

Mitigation on the owner's phone: `connection.autoconnect-retries 1` on
the gsm connection. Before, a failed autoconnect was followed by the
next one within 5 ms; after, the same failure (registration timeout) was
not followed by another autoconnect, and the next dial came from
`diting-modem-redial`, which has the 15-minute back-off. The three ip
types and the missing back-off are NetworkManager's; not changed here.

## The network mode fell back to "2G preferred" after every boot (2026-11-24, RESOLVED)

The mode chosen in the desktop's mobile network settings (3G, 4G, 5G,
prefer 5G) lasted through ModemManager restarts and a modem firmware
restart; after a boot the settings showed 2G, 3G, 4G, 5G with 2G
preferred again. The modem keeps the mode in its EFS, which rmtfs does
not write back, and `diting-modem-setup` allowed every technology on
every boot. It has to: left alone the modem stays on GSM only, which
leaves an LTE-only carrier without service. Nothing set the preferred
technology, so it was whichever came first in the modem's acquisition
order.

Now the boot script allows what `/etc/diting/modem-mode` names, and
`diting-modem-mode.service` hands the same file to ModemManager once it
runs. That second step is needed because only ModemManager can set the
preferred technology: qmicli cannot set the acquisition order. Measured
on the modem, starting from "2G preferred":

| step | mode preference | acquisition order |
| --- | --- | --- |
| boot script alone | `umts, lte, 5gnr` | `umts, lte, 5gnr, gsm`: 3G preferred |
| then `apply-mode` | `umts, lte, 5gnr` | `5gnr, lte, umts, gsm`: 3G, 4G, 5G, prefer 5G |

Without the file every technology is allowed, as before. A mode chosen
in the desktop lasts until the next boot; to keep it, put it in the
file. Both steps were run by hand on the live modem first; the next
boot then showed 3G, 4G, 5G with 5G preferred (owner-checked; the unit
finished 50 s after boot).

## A SIM moved to the other slot while the system runs (2026-11-25, RESOLVED on the owner's phone)

First real test: a boot with the SIM in slot 2, the card moved to slot 1
at 75 s.

With the first version of the recovery (activate the session, restart
ModemManager only):

- 75 s: the SIM switch made ModemManager re-probe; its new objects failed
  with "GW primary session index unknown": no session for slot 1.
- 137 s: the watchdog's "modem gone" branch restarted ModemManager.
  Without a usable SIM it needs 70 s to expose a modem, and two polls
  without one counted as a lost modem.
- 198 s: "SIM swapped: session activated". The session on slot 1 was
  activated, ModemManager restarted, the modem registered.
- 218 s: NetworkManager dialled. Six seconds later the dial failed
  (`CallFailed`, cm 1140) and the modem began to throttle PDN calls; the
  next activation got `pdn-ipv4-call-throttled`. With
  `autoconnect-retries 1` nothing dialled after that and the watchdog
  backed off for 15 minutes: no data.
- By hand at 01:35: a modem firmware restart, then ModemManager: the
  first dial went through, 66 s after the start.

What changed in `diting-modem-redial` (device 0.7.35):

- `diting-modem-setup ensure-session` alone decides whether a card has no
  session. The check no longer waits for ModemManager to expose the
  modem, so the recovery starts within a minute of the card being
  inserted.
- The recovery restarts the modem firmware as well
  (`restart_modem_fw`, the watchdog's third level), because the modem
  keeps the state of the card that left.
- A ModemManager younger than 90 s is not "missing".

Measured afterwards with the session removed by hand: the watchdog acted
at +63 s, the modem ran again at +68 s, the session was back at +73 s,
connected at +131 s with the first dial. A real tray swap with this
version had not been done when this was written.

The test also showed two other things, each with its own section below:
ModemManager reported the active SIM slot wrongly with the card in slot
1, and the registration kept dropping with the card in either slot.

## ModemManager showed no SIM in the active slot with the SIM in slot 1 (2026-11-25, RESOLVED: modemmanager diting3)

The modem reports both physical slots as active (dual standby, mapped to
logical slots 1 and 2). `uim_get_slot_status_ready()` in `mm-shared-qmi.c`
stored every active slot as the primary one, so the last one won. With the
SIM in slot 2 that happened to be right. With it in slot 1 ModemManager
showed `slot 2: none (active)`, took no primary SIM from the slot list,
and created a second SIM object for the card from the card status
(`SIM/1`, next to `SIM/0` in slot 1). The desktop showed no SIM in the
active slot while the modem was registered and data worked. A modem and
ModemManager restart did not change that; upstream main has the same code
(checked 2026-11-25).

`packages/modemmanager/0003` takes the first active slot that has a SIM as
the primary one, the last active slot only when none of them has one;
only that SIM is active. Modems with one active slot are not affected.
Measured with diting3 and the SIM in slot 1: `slot 1: SIM/0 (active)`,
`primary-sim-slot 1`, one SIM object.

## The registration dropped every few minutes on an LTE-only carrier (2026-11-25, RESOLVED on the owner's phone)

With the China Telecom SIM the modem registered, held it for 22 seconds to
4 minutes 44 seconds, then searched for minutes (12 minutes from 22:04,
more than 10 from 22:55), over and over,
in whichever slot the card was. ModemManager reported
`network-rejection-error: cs-domain-not-available`; RSRP was -84 dBm while
registered, so not coverage, and it happened in a boot without a single
suspend. The modem was voice-centric with the CS and PS domains and CS
voice preferred (where it takes that from was not checked), and the
network had no CS domain for it.

QMI NAS "Set System Selection Preference" has the usage, voice domain and
service domain preferences as fields (0x21, 0x23, 0x18); qmicli does not
send them. `diting-nas-pref` does (python3-gi with gir1.2-qmi-1.0).
`usage="data"` and `service_domain="ps-only"` in `/etc/diting/modem-mode`
are applied by `diting-modem-setup` on every boot (device 0.7.35); the
modem keeps them over ModemManager and modem firmware restarts.

- Before: 2 losses in 10 minutes. After, in 67 minutes: none on its own;
  the two longest stretches between ModemManager restarts, 14 and 15
  minutes, stayed registered; no network rejection reported any more.
- 7 blips of 5 to 24 seconds in that hour, each 22 to 24 seconds after
  one of seven ModemManager starts. ModemManager's start makes the modem
  re-select once; it is seen in earlier logs too.
- Not isolated which of the two settings matters; the voice domain is
  still CS preferred. Calls do not work in this mode: next section.
- The modem applies the fields asynchronously and invalidates the QMI
  client that asked, and writing them reorders the acquisition order
  (the preferred technology became 3G once). At boot
  `diting-modem-mode.service` sets the preferred technology after them;
  by hand, `diting-modem-setup apply-mode` does the same.

Not taken: the carrier configuration. The firmware has
`mcfg_sw/generic/China/CT/Commercial/VoLTE_OpenMkt`, the modem had no
China Telecom configuration loaded, but `qmicli --pdc-load-config`
segfaults: libqmi 1.38 frees the pointer into the mapped file after
computing the checksum (`qmicli-pdc.c`, `load_config_file_from_string`;
upstream main has it too).

## A ModemManager restart cost five minutes of mobile data (2026-11-25, RESOLVED)

Every ModemManager restart with a data connection up made the first dial
of the new ModemManager fail after six seconds (`CallFailed`, cm 1140),
the next ones `pdn-ipv4-call-throttled` / `pdn-ipv6-call-throttled`; five
of five, on upgrade, on restart by hand and after the crashes of
2026-11-24. A dial five minutes later went through (02:31:49, 02:46:15).
A restart with no connection up was followed by a good first dial, four
of four. The 15-minute back-off of `diting-modem-redial` was waiting for
this.

Not a call left in the modem: read through a WDS client bound to mux id
1, the call is `disconnected` within a second of ModemManager dying. What
matters is how it ended. A disconnect by the ModemManager that owns it
(`nmcli connection down`) was followed by a good dial three seconds
later.

- `diting-mm-stop` is now `ExecStop=` of ModemManager.service (drop-in
  `50-diting-clean-disconnect.conf`): it deactivates the gsm connection
  through the running ModemManager (`nmcli --wait 10 connection down`),
  then sends it SIGTERM. With `ExecStop=` set systemd sends no signal of
  its own. A first version said `nmcli --timeout` (there is no such
  option) and let the error through: the connection stayed up.
- NetworkManager stops auto-activating a connection it deactivated on
  request, so nothing dialled once ModemManager was back.
  `diting-modem-redial` now dials at once in its first three polls after
  ModemManager was started, whatever its back-off. Its first version
  waited for two polls and honoured the back-off; 11 minutes without data.

Measured with a connection up, `systemctl restart ModemManager`: the
hook's disconnect, the restart, the watchdog's dial 59 s later, connected
77 s after the restart, the first dial through; again 87 s. No throttled
line. A crash or a SIGKILL cannot be intercepted: the old five minutes
then.

One case is not covered (2026-11-25, 21:35): a connection that was
already dead, connected with no packets. The restart of ModemManager by
`diting-modem-redial` ran the hook's disconnect, and the two dials after
it were throttled all the same; data came 2 min 38 s after the restart.
The record of the day has the sequence.

## Calls on China Telecom: 47 seconds of dialling, then terminated (2026-11-25, OPEN)

`mmcli -m any --voice-create-call` as root (as a user over SSH PolicyKit
refuses it): the call stays in `dialing` for 47 s, then `terminated
(unknown)`; it never left the dialing state, so the number was not
alerted. The PS attachment blips when the call starts (attached,
detached, attached again within 0.6 s). With data-centric usage and PS
only there is no CS voice, and the network reported no CS domain: calls
need VoLTE, i.e. IMS. SMS was not tested.

What there is, and what is missing:

- The modem runs the IMS services (IMSA answers `InvalidOperation` until
  a client is bound to it).
- libqmi 1.38 queries only: IMS registration status, IMS services status,
  the IMS service enable setting, and the IMS PDN (`imsdcm`).
- The IMS stack itself, SIP registration and call control, is in the modem
  firmware, not on the AP: `modem.mbn` has the SIP stack and the
  registration manager, and the vendor libraries of Android have no SIP.
  What the AP has is the IMS bearer (APN `ims`) and a QMI service for the
  modem, 0x302. Both were done by hand on this image; the modem still does
  not register. Next section.
- `diting-voice-call` starts the audio graphs while ModemManager has a
  call; it has not been exercised here.

## VoLTE: the IMS bearer is the AP's to bring up, the registration is not started (2026-11-25, OPEN)

Read from the vendor libraries of this phone (`lib-imscommon`,
`lib-imsservice`, `libdsi_netctrl`, `libqdi`, `libqmiservices`) with
Ghidra, and tried on the modem with raw QMI over QRTR.

- The AP hosts QMI service 0x302 (`imsdcm`; libqmi's definitions have its
  three messages since 1.37). As soon as it is there the modem sends 0x23
  (its link-local address and port 9099), 0x2e (register app state) and
  0x34 (RCS service mask). The daemon of this phone answers 0x2e with the
  result alone (and sets a property for the framework); an older daemon,
  in a trace of another phone, answered `0x10 = 0x5f` and its modem then
  asked for the bearer (0x20). Both answers were given here; the modem
  never asks. The link-local handshake on that service is for RCS, not
  for registration.
- The IMS bearer the modem accepts: `Start Network` with APN `ims`, IP
  family IPv6 (TLV 0x19 = 6), extended technology preference link-local
  (TLV 0x34 = 0x8888) and call type embedded (TLV 0x35 = 1), after
  `Bind Subscription` and `Bind Mux Data Port`: result 0. The same
  without TLV 0x34 is `CallFailed`, verbose 2/210, "IPv6 PDN call
  disallowed"; IPv4 is 2/208, "IPv4 PDN call disallowed": the IMS APN of
  China Telecom takes IPv6, and only as link-local. The bearer has no
  global address: `Get Current Settings` gives a `fe80::`/64 address and
  gateway. Android's library asks the modem first with WDS 0xFFF2 (route
  look up); the modem answers result 0 and no mux id. With the call up
  and nothing else done for six minutes, then with 0x302 hosted for
  three and a half minutes more, the modem did not restart; the data call
  is not affected.
- A `PDP Activate` indication sent on 0x302 by hand, with the bearer up
  and the handshake answered, changes nothing. Its PDP id is the one the
  AP gives when it answers the modem's own `PDP Activate Request`, and
  the modem never sends one here.
- Not what starts the modem: the IMS settings (voice over LTE, SMS, XCAP,
  service and autoconfig enabled, read back as enabled); NAS
  voice-centric, IMS PS voice preferred, CS and PS for a minute; the
  bearer and the handshake together; IMSA indications registered for
  ninety seconds. IMSA says `not-registered`, error 0, and
  `ue_to_tas_service_status` `available` on WWAN: no attempt is made.
- `rmtfs` runs with `-r -P -s`. In rmtfs 1.1.1 `-P` means the raw EFS
  partitions and `-r` read-only: the modem starts from the Android EFS
  as it is on disk, and what is written goes to memory only, so a reboot
  drops it. PDC lists no software configuration selected; to Get Default
  Config Info the modem answers `SW_DEFAULT`. The 25 software
  configurations of the EFS have names through Get Config Info; the one
  for China Telecom is `VoLTE_OPNMKT_CT`, id `5B411D9B…`. The AP side
  has none: the `mbnconfig` partition is all zeros and `cust` has no
  mcfg tree.
- The carrier configuration applied the way the RIL of the phone does it
  (`libxiaomi_qcril.so`): PDC Set Selected, then PDC Activate 0x27 with
  activation type 0. The modem applies it online: NAS becomes CS and PS,
  voice-centric, IMS PS voice preferred, the profiles become `ctnet`,
  `IMS`, `ctwap`, `sos`, and IMSA and IMS settings stay up. The modem
  camps on LTE and still does not register or ask for the bearer. Done
  with a modem stop and start instead, it came up without IMSA (0x21)
  and IMS settings (0x12), with a network rejection on LTE and without
  the selection. PDC Deactivate 0x2B holds only until the next modem
  restart, which brings the configuration back and resets the NAS
  fields; after the activation PDC lists no platform configuration any
  more, where one was active before. A reboot undoes all of it.
- What else the RIL does at start, replayed without effect: PDC 0x2E
  switches the modem's auto selection on (the RIL reads the state from
  EFS, `/nv/item_files/mcfg/mcfg_autoselect_by_uim`); after a modem
  restart with it on, the handshake on 0x302 ran 0x23, 0x34, 0x23, 0x2e,
  0x34, 0x33 as in the trace of the other phone, then stopped, and
  nothing was selected. IMS settings 0x2A with TLVs 0x11, 0x1F, 0x2D,
  0x31 set, as the RIL's IMS module does at its start. "Set IMS
  registration" of the RIL is IMS settings 0x8F with "service enabled"
  for the registered state, sent after NAS voice domain PS preferred;
  both were set.
- The EFS can be read with the service the RIL uses for it: Xiaomi's
  extension service 0xFFE4, message 0x02, command 4 in the payload.
  `/nv/item_files/ims/IMS_enable` and `ims_operation_mode` are 0, on
  both subscriptions.
- The firmware's own carrier rules map 460-03/05/11/12 to `CT`,
  `volte="true"`, carrier index 19.
- Not found: what starts the registration.

Two accidents while trying, for the record:

- The rmnet driver keeps the data format per physical port, and
  `rmnet_newlink` resets it to the default for every link created without
  flags. `ip link add link rmnet_ipa0 … type rmnet mux_id N` without
  `ingress-deaggregation on ingress-mapv5-checksum on
  egress-mapv5-checksum on` (the flags of ModemManager's link) made the AP
  send every frame in a format the modem's IPA does not expect. The modem
  stopped with `IPA Assert … IRQ_STTS: 0x00016080` twice (16:22, 16:41)
  and remoteproc recovered it both times. A link on rmnet_ipa0 is only
  added with those flags.
- A raw `Set System Selection Preference` with the mode mask 0x0004, meant
  as LTE only: in libqmi's layout gsm is 2, umts 4, lte 8, td-scdma 16,
  5gnr 32. The restore, 0x0016, has neither LTE nor 5G, and writes of
  0x002C did not take until ModemManager set the modes: eight minutes
  without service (17:16 to 17:24). Modes are changed through
  ModemManager, `mmcli -m 0 --set-allowed-modes="3g|4g|5g"
  --set-preferred-mode="5g"` as root, not with raw QMI.

The tools are in the repository's `tools/ims/`, not in the image:
`diting-dcm.py` (hosts 0x302, answers the modem, sends indications),
`diting-imshelper.py` (the same, and brings the bearer and its link up by
itself when the modem asks), `diting-imscall.py` (the bearer and its
link with the port's flags; stops both on exit), `diting-rawqmi.py`,
`diting-ims.py` (status, settings, PDC), `diting-pdc.py` and
`diting-pdc-names.py` (carrier configurations: list, selected, default,
names), `diting-efs.py` (reads EFS items).

## The day of 2026-11-25 on ModemManager and IMS: what changed, what was tried (RECORD)

### What changed in the image

Three commits, all on `main`, not pushed when this was written:

- `480bf10` modemmanager diting3: patch `0003` in
  `packages/modemmanager/`, `src/mm-shared-qmi.c`, the first active slot
  with a SIM is the primary one (+20/−6); README and
  `build-modemmanager.sh` with it.
- `b5ab5d9` device 0.7.35: `diting-mm-stop` as the stop hook of
  ModemManager (`50-diting-clean-disconnect.conf`), `diting-modem-redial`
  with the dial after a ModemManager start and the session activation on
  a SIM swap, `diting-modem-setup` keeping the network mode
  (`diting-modem-mode.service`), `diting-nas-pref`. No ModemManager source
  in it: these fixes are scripts and units around ModemManager.
- `244bb83` docs: the sections of 2026-11-24 and 2026-11-25 above.

The patches of ModemManager are quilt patches kept next to Ubuntu's
source archives in `packages/modemmanager/`, not in a source tree:
`build-modemmanager.sh` copies them into `debian/patches` of the archive
version and builds `1.25.95-1ubuntu1diting3`. `0001` came with `739cc5b`
(2026-10-14), `0002` with `2f6d917` (2026-11-22), `0003` with `480bf10`.

With all of it installed, the phone was rebooted once, at 21:12. The
mode and the NAS fields were the configured ones, and the shutdown
before had gone through the hook's disconnect (NetworkManager
deactivated the connection as ModemManager stopped, 21:12:16). The dial
after that boot was not clean, from the journal: the first two attempts,
82 s and 137 s after boot, were refused as `pdn-ipv4-call-throttled` and
`pdn-ipv6-call-throttled`, data was up at 199 s, and `diting-modem-redial`
backed off for the throttle at 21:17:02.

### What was tried on IMS, in order

All of it with tools outside the image and raw QMI; nothing of it is in
the image. The modem's EFS is a copy in memory (`rmtfs -r`), so every
write below lasted until the reboot at the end.

1. 16:15 to 16:18. `Start Network` for APN `ims` with a client type in
   `Bind Mux Data Port` (TLV 0x13: none, 1, 2, 255), on mux 20 to 27:
   refused, 2/208, 2/241 or 2/236. The WDS route look up 0xFFF2 answers
   result 0 for `ims` with IPv6 and the link-local preference only.
2. 16:18. With TLV 0x34 = 0x8888: accepted (handle 0x120e3cd0, mux 21);
   the same call on mux 0 gave the same handle.
3. 16:21. 0x302 hosted: the handshake. 16:22: the first modem crash (the
   rmnet link without flags), recovered by remoteproc.
4. 16:28 to 16:38. The bearer alone for six minutes, then with 0x302
   hosted for three and a half: no crash. 16:41: the second crash, the
   same mistake with the link up.
5. 16:46 to 16:51. Bearer, link with the flags, the modem's address on
   it; `PDP Activate` and `Address Change` indications, first with a
   wrong layout, then with the right one (instance 1, the address the
   network gave): no reaction. A probe left a second bearer without an
   owner; removed by a modem restart at 17:03.
6. 17:04. The whole sequence once more from a modem restart: not
   registered.
7. 17:12. NAS voice-centric, IMS PS voice preferred, CS and PS for a
   minute (a first attempt at 17:08 had not taken): not registered, the
   owner's fields written back.
8. 17:16 to 17:24. The mode mask mistake: eight minutes without service
   (above).
9. 17:29 to 17:37. `VoLTE_OPNMKT_CT` selected and the modem stopped and
   started: applied, but no IMSA and no IMS settings, a network
   rejection on LTE, no selection afterwards. A second start: generic.
10. 17:50, 20:37, 20:59. 0x2e answered with `0x5f`: no change.
11. 19:42 to 19:45. The modem's auto selection switched on (PDC 0x2E),
    then a modem restart: nothing selected; the handshake in the order
    of the other phone's trace at the activation only.
12. 20:24 to 20:31. The carrier configuration selected and activated
    online; `Start Network` without the link-local preference refused
    with the named reasons; bearer, link and indications once more: not
    registered.
13. 20:50 to 20:53. IMS settings 0x2A as the RIL sends it; EFS items
    read. 20:56: IMSA indications registered for ninety seconds.
14. 21:00 to 21:09. Deactivate, auto selection off, a modem restart: the
    configuration came back with the NAS fields of the carrier, and no
    platform configuration; activate for the platform and an empty
    selected list: no change.
15. 21:12. The phone rebooted to drop all of it.
16. 21:44 to 21:54. The tools, collected into the repository
    (`tools/ims/`, `8e2a810`), run once more as they are there: the
    read-only requests; 0x302 hosted three times for 3 to 15 s, the modem
    sending 0x23, 0x2e and 0x34 at once each time; one IMS data call for
    30 s on mux 12, accepted and stopped, its link deleted. Not
    registered.

Counted in the trials above: two modem crashes, five modem restarts by
hand, one reboot; and two recoveries, not by hand, of
`diting-modem-redial` after the reboot (next section).

### The cellular connection after the reboot: two recoveries by diting-modem-redial

`diting-modem-redial` probes the cellular path once a minute with a ping
bound to `qmapmux0.0`, and acts when three probes fail while
NetworkManager shows the connection activated ("connected, no packets"):
the first time it restarts ModemManager, the second time the modem
firmware too. Both happened in the boot of 21:12:

- 21:16:01: data up. 21:17:02: back-off for 15 minutes, for a throttled
  dial in ModemManager's log.
- 21:33 to 21:35: three probes failed. 21:35:11: ModemManager
  restarted. The hook's disconnect ran (NetworkManager deactivated the
  connection at 21:35:11), and the two dials after it were throttled all
  the same (21:35:48, 21:36:48). 21:37:49: data up, 2 min 38 s after the
  restart. 21:39:52: back-off again, during which nothing probes the
  path.
- 21:54:53 to 21:56:58: the first three probes after the back-off
  failed. 21:56:59: the modem firmware stopped and started, ModemManager
  restarted at 21:57:16; registered at 21:57:55, data up at 21:58:09 on
  the first dial, no throttle. A ping bound to `qmapmux0.0` was answered
  at 21:59:45.

What made the path dead is not determined. Neither connection was probed
between its dial and the failed probes that ended it: the back-off
followed each dial. Both were dialled after two throttled attempts; the
one after the restart of the firmware, on the first dial, has held. Each
may have come up dead, as the header of `diting-modem-redial` describes
for a fresh bearer after a mid-session disconnect, or died later. What
ran on the modem in those windows: a read-only check at 21:27 (the
selected carrier configuration, NAS queries) in the first, the tools of
item 16 in the second. In the boot before, from 17:04 to 21:12, the same
probe found nothing wrong in four hours of IMS trials, the IMS data call
included. The layers known before this day are in CN-ADAPTATION.md
("zombie bearers after redial", the network's PDN throttle); here the
watchdog did what it is there for, twice in 22 minutes.

A check that proved nothing: after item 16, pings to 223.5.5.5 were
answered, and the path was taken as fine. They left over Wi-Fi, the
default route of the lower metric; only a ping bound to `qmapmux0.0`
says something about the cellular path.

A probe of its own then, with no IMS tool running: a ping bound to
`qmapmux0.0` every 8 s from 22:03:14 to 22:20:13, 125 of them, all
answered. The connection of 21:58:09 was alive from its fifth minute to
its twenty-second; the two before were first found dead 17 minutes after
their dial, unprobed until then.

### diting-hardware-recovery: the USB controller reset every two minutes, one reset oopsed the kernel

Not ModemManager, but the same day on the same phone. Found at 21:42;
the fix is device 0.7.36, and what is verified of it is below.

- `check_usb` took `usb0` without carrier for a stuck gadget whenever
  the Type-C data role contains "device". It does in both roles of this
  kernel (7.2.10): the current role is the one in brackets, `host
  [device]` is the device role and `[host] device` the host role. So the
  check was "usb0 has no carrier", and there is none as a matter of
  course with nothing on the cable or with a charger: no host ever
  attaches the gadget. `recover_usb`, an unbind and a bind of `dwc3-qcom`
  and `diting-usb-gadget start`, ran every 126 s: 15 times in the boot of
  21:12 from 21:14:53 on, 97 times between 05:41 and 09:47 in the boot
  before. In the journal back to 2026-11-22 there is no USB reset before
  those: none is on record that helped.
- 21:42:16: one of those binds oopsed the kernel: `Unable to handle
  kernel NULL pointer dereference at virtual address 0x10` in
  `usb_ep_alloc_request`, called from `composite_dev_prepare` and
  `configfs_composite_bind` under `dwc3_qcom_probe`: the gadget was
  still bound and waiting for its controller, and was bound again in the
  probe of the next one. The endpoint it was given was NULL (x0 in the
  trace), the one `composite_dev_prepare` takes from the gadget. The
  oops killed the script (SIGSEGV); systemd started it again at
  21:42:26.
- 21:44:26: the next reset began and never logged "recovery done". The
  script (`/bin/sh`, PID 8977) has been in state D since, most likely in
  the write to the driver's `bind` or `unbind`, the only steps of the
  reset that run without a child process. It cannot be stopped, so the
  next shutdown may wait on it.

The fix:

- `check_usb` counts `usb0` without carrier as stuck only when a host
  has the gadget: the UDC it is bound to says so with a state other than
  "not attached" (`/sys/class/udc/<udc>/state`). With nothing on the
  cable, with a charger, or in host mode (no UDC), nothing is touched.
- `recover_usb` takes the gadget down first (`diting-usb-gadget stop`),
  then unbinds and binds `dwc3-qcom`, then brings the gadget up again;
  it logs when the gadget is bound to no controller afterwards.

Verified on the phone:

- `check_usb` with a fake tree, eight cases as intended.
- In the boot with the wedged controller, the new script run by hand for
  340 s in the state that had produced the resets (no carrier, UDC "not
  attached", device role): five polls, no reset.
- The phone was rebooted for the rest (22:49). With the script in state
  D the shutdown took three minutes longer, two timeouts of 90 s, and
  went through. With a host on the cable and the gadget taken (UDC
  "configured", carrier on `usb0`), `recover_usb` run by hand: 7 s, the
  gadget taken down, the controller unbound and bound, the gadget up and
  bound again; no oops, nothing left in state D, the watchdog's unit
  untouched. Seven seconds after it the UDC was still "not attached"; the
  host had the gadget again within 27 s, with the carrier, and the Mac
  was answered at 172.16.42.1.
- Not produced: the watchdog firing on its own. That takes a host that
  has the gadget without bringing `usb0` up. `ip link set usb0 down` is
  not that: an interface that is down shows no NO-CARRIER either, and
  the watchdog left it alone, as it should.

Left as it is: a host that has the gadget but never brings its network
interface up leaves `usb0` without carrier, and the reset would repeat
every 126 s, as before the fix. A limit on consecutive resets would stop
that. And after a reset NetworkManager shows `usb0` disconnected, with
the gadget script's own 172.16.42.1/24 on it: `recover_usb` starts the
script without the empty `DITING_USB_ADDR` of its unit. So it was before
the fix, and the Mac is reached through it all the same.

The phone's package: dpkg has had 0.7.26 since 2026-11-21. The files of
the later versions were copied onto it by hand, 0.7.36's as well: a deb
upgrade runs `update-initramfs`, and with it the hook that writes the
boot images.

### The phone at the end

After the reboot of 21:12: mode UMTS, LTE, 5G with 5G preferred; PS
only, data-centric, CS preferred; registered on 5G, at home; no modem
crash since boot; no IMS link; the rmnet port's data format as
ModemManager left it; nothing left in `/tmp` and `/run` from the trials.
The cellular connection is the one of 21:58:09, after the second
recovery, probed as above. The mode and the NAS fields were read again
at 22:20, after the restart of the firmware: unchanged.

Rebooted again at 22:49, for the USB fix. This time the first dial went
through: data up 57 s after boot, no throttled line. Registered on 5G,
the modes and the NAS fields as before, pings bound to `qmapmux0.0`
answered at 23:01. A host is on the cable: the gadget is configured,
`usb0` has its carrier, and the Mac reaches the phone at 172.16.42.1.
The watchdog runs the fixed script; nothing is left in `/tmp` and
`/run`.

### The owner's observation

The owner watched the cellular network over this day of debugging and
found it very stable (their words, 21:16). The journal of the same
evening has the two recoveries above, at 21:35 and 21:57.
