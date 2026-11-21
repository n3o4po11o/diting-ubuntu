# CN adaptation log: Redmi K50 Ultra (diting) on the x86_64 build host

Everything needed to rebuild, flash and operate the CN variant
(OS3.0.3.0.VLFCNXM, S5KHM6 wide camera, no Gunyah/pvmfw, PDN
throttling), worked out 2026-11-21/22. Fixes are commits on the
`x86_64-build` branch; document links below.

## Build environment

- Remote build host `mt8788-build` (Debian 13 x86_64, 15 cores):
  cross kernel (aarch64-linux-gnu-gcc 14.2), qemu-user-static buildd
  chroots for the deb packages, qemu chroot builds for
  sensors/libcamera/phoc. All orchestration in tmux
  (`k50ultra-build/dl/flash`), logs under `output/logs/`, stage stamps
  in `~/k50ultra/.stamps` for resumable chains.
- The local Mac only edits the repo and archives artifacts.

## CN-specific problems found and fixed

| Problem | Root cause | Fix (commit) |
| --- | --- | --- |
| First boot: no firmware, all DSPs dead | `diting-mark-boot-successful` dies on a stale backup-GPT entry CRC (CN flash tool never updates it) | read the slot from the primary table only; rebuild the backup array before writing (device 0.7.18) |
| Firmware build fails | CN persist has no `audio/` speaker calibration | optional tree in `diting-build-firmware` (0.1.2) |
| Wide camera module missing | CN units carry S5KHM6, not S5KHP1; camregs converter chokes on op 3/4 | convert op3 (skip) / op4 (write+wait kept); module optional (0.1.3) |
| Wi-Fi never up | ath11k requests qmi-chip-id 18 (chip_id 0x12); board-2.bin entries said 2 | entries for 18 + chip-id-agnostic fallbacks (0.1.3) |
| Modem crash-loops (EFS rmts_get_buffer) | Ubuntu rmtfs 1.1.1-2 enables rmtfs-dir which steals the QRTR port | mask + preset (0.7.19) |
| NM/ModemManager churn | MM ran with `--test-quick-suspend-resume`; dbus rejects NM disconnects | drop the flag, watchdog covers the resume case (0.7.24) |
| Mobile data dies intermittently | three layers: usb0 default-route hijack (metric), zombie bearers after redial, PDN-call-throttled from the CN network | route-metric 30000 (0.7.19); `diting-modem-redial` watchdog: redial -> MM restart -> remoteproc reset, 15 min backoff when throttled (0.7.23..0.7.25) |
| 1972 clock poisons snap seeding + PAM | no usable RTC (see hardware facts) and no clock floor on first boot | ship `/var/lib/systemd/timesync/clock` with the build time (`build-rootfs.sh`) |
| SPMI write storm after r47 | AP cannot write the PMK8350 RTC (arbiter denies); kernel NTP sync worker retries 47/s | allow-set-time reverted, rtc-sync removed, r50 |
| CDSP log flood | duplicate handover IRQ logged at err level | patch 0097, r48 |
| Bluetooth toggle dead | server-built boot images carry no `local-bd-address` (no machine-id at build time) | `diting-bt-fixup`: first boot persists an address, regenerates the boot images and dd's them to the boot partitions before the firmware-setup reboot (0.7.28) |
| UI froze at idle dim | DSI brightness write timed out on the wedged display pipeline | workaround: disable idle blank (KNOWN_ISSUES); recurred once after churn - watch it |
| Rootfs "clean with errors", growfs blocked | `rw` on the cmdline skips systemd-fsck-root; unclean poweroffs accumulated damage | boot `ro`; fsck runs when the fs carries errors (also the failed-boot pitfall: an fsck that cannot repair drops into emergency with no shell - repair from the initramfs debug shell, see runbook) |
| UFS bad blocks (EIO on reads) | storage-level, visible as e2fsck I/O errors | full reflash of userdata (fresh ext4, FTL remaps); monitor dmesg |
| arm32 binaries ENOEXEC | SM8475 is asymmetric: only the 3x A710 have AArch32 EL0; kernel gates support behind a cmdline param | `allow_mismatched_32bit_el0` on the cmdline (native arm32 on the A710 cluster) |
| No USB host mode | bring-up DT pinned `dr_mode = "peripheral"`, no role-switch wiring | patch 0098 (r51): otg + usb-role-switch + pmic_glink connector graph; NM ethernet management (0.7.27, docs/OTG.md) |

## Hardware facts (measured, do not re-litigate)

- **The AP cannot write the PMK8350 RTC**: the SPMI PMIC arbiter
  rejects every write to sid0 0x61xx. Time persistence =
  timesync clock file + NTP.
- **USB is 2.0-only on this board**: the SoC has USB3, the mainboard
  does not wire the SuperSpeed lanes. OTG tops out at high-speed.
- **Asymmetric AArch32**: CPU0-3 (A510) and CPU7 (X2) have no
  AArch32 EL0; only CPU4-6 (A710) do. No EL2 for the kernel either:
  KVM is unavailable, period (pvmfw/Gunyah does not apply - the SoC
  firmware is QHEE-era and the device has no pvmfw partition).
- CN persist on the real unit **does** contain the speaker
  calibration and `qca6490/wlan_mac.bin` (the factory ROM image does
  not - test extraction against real hardware).

## Deliverables

- `release/final-public/`: boot.img, vendor_boot.img, sparse
  rootfs.img, flash script, checksums. PIN 147147, first boot
  self-provisions (clock floor, firmware extraction, Bluetooth
  address into the boot partitions, one automatic reboot).
- `release/final-owner/`: same kernel; built-in debug SSH key
  (`~/.ssh/diting_debug_key` on the Mac), passwordless sudo,
  `diting.debug=usb` initramfs shell.
- Flash: `fastboot flash boot_a boot.img && fastboot flash
  vendor_boot_a vendor_boot.img && fastboot erase dtbo_a &&
  fastboot flash userdata rootfs.img && fastboot reboot`.
- On-device boot images regenerate via
  `/etc/kernel/postinst.d/zz-diting-bootimg $(uname -r)` whenever the
  kernel package (re)installs - that is also how the Bluetooth
  address gets in.

## Operational runbook

- SSH: `ssh -i ~/.ssh/diting_debug_key ubuntu@172.16.42.1` (USB) or
  the phone's Wi-Fi address. Owner images only.
- Initramfs rescue (owner images): `/dev/cu.usbmodemditing*` on the
  Mac, 115200; a root shell respawns from init-top.
  `diting.debug=hold` in `/etc/diting/cmdline` parks the boot for
  filesystem repair (`e2fsck -fy /dev/sda37` with PID 1 frozen).
- Cellular: APN for China Telecom is `ctnet` (`sudo nmcli c add type
  gsm ifname '*' con-name mobile gsm.apn ctnet autoconnect yes`); the
  redial watchdog recovers hangs; the network throttles PDN calls
  after heavy churn - leave it alone for 15+ minutes.
- USB ethernet: docs/OTG.md.

## Open problems

1. **No audio** (KNOWN_ISSUES.md): the CN ADSP firmware's SPF never
   registers its GPR port; every graph operation times out. Bisect:
   did audio ever work on any boot? Decisive test: run the EEA
   firmware_mnt's adsp image with the rest CN.
2. HM6 wide camera needs a mainline sensor driver (camregs already
   built by the firmware extraction).
