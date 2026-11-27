# CN adaptation log: Redmi K50 Ultra (diting) on the x86_64 build host

Everything needed to rebuild, flash and operate the CN variant
(OS3.0.3.0.VLFCNXM, S5KHM6 wide camera, no Gunyah/pvmfw, PDN
throttling), worked out 2026-11-21/24. Fixes are commits on the
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
| Bluetooth address lost again after every flash | `diting-bt-fixup` runs once per rootfs (marker); boot images built on the server never carry `local-bd-address`, so after each `fastboot flash` the kernel starts the QCA6490 unconfigured (`DOWN RAW`, invisible to bluetoothd); a rootfs reflash also gives a new machine-id-derived address | `diting-bt-setup.service`: bound to hci0, `btmgmt public-addr` each time the controller comes up unconfigured (every boot, every re-probe; ~2 s, no reboot, no boot partition write). `diting-bt-address` derives the address from the factory Wi-Fi MAC in `persist:/qca6490/wlan_mac.bin` (0.7.34) |
| UI froze at idle dim | DSI brightness write timed out on the wedged display pipeline | workaround: disable idle blank (KNOWN_ISSUES); recurred once after churn - watch it |
| Rootfs "clean with errors", growfs blocked | `rw` on the cmdline skips systemd-fsck-root; unclean poweroffs accumulated damage | boot `ro`; fsck runs when the fs carries errors (also the failed-boot pitfall: an fsck that cannot repair drops into emergency with no shell - repair from the initramfs debug shell, see runbook) |
| UFS bad blocks (EIO on reads) | storage-level, visible as e2fsck I/O errors | full reflash of userdata (fresh ext4, FTL remaps); monitor dmesg |
| arm32 binaries ENOEXEC | SM8475 is asymmetric: only the 3x A710 have AArch32 EL0; kernel gates support behind a cmdline param | `allow_mismatched_32bit_el0` on the cmdline (native arm32 on the A710 cluster) |
| Modem unstable across the day | MM's suspend handling drops the QRTR modem and the re-scan fails (~1 suspend in 6); watchdog noticed only minutes later | `diting-mm-resume.service`: on every resume, restart MM immediately when `mmcli` sees no modem (0.7.29) |
| No USB host mode | bring-up DT pinned `dr_mode = "peripheral"`, no role-switch wiring | patch 0098 (r51): otg + usb-role-switch + pmic_glink connector graph; NM ethernet management (0.7.27, docs/OTG.md) |
| ModemManager segfaults every few minutes while dials fail | the phone ran a ModemManager build without the netlink fix (`packages/modemmanager/0001`): `/tmp/mm2.deb` of 2026-11-22 07:40, labelled `diting2`, with 0002 only; 12 SIGSEGVs in 75 min on 2026-11-24 | reinstall `modemmanager` and `libmm-glib0` from the build host's `output/debs/`; check with `md5sum /usr/sbin/ModemManager` (packages/modemmanager/README.md, KNOWN_ISSUES.md 2026-11-24) |
| Twelve dials in a second after a failed connect | NetworkManager tries three ip types per activation and auto-activates again 2 ms after a failure, four tries by default; every failed dial became twelve and prolonged the PDN throttle | `connection.autoconnect-retries 1` on the gsm connection (per phone, 2026-11-24); `diting-modem-redial` keeps the retry with its back-off |
| Network mode back to "2G preferred" after every boot | the modem forgets the mode (rmtfs read-only) and `diting-modem-setup` allowed every technology; nothing set the preferred one | `/etc/diting/modem-mode` and `diting-modem-mode.service` (device 0.7.35) |
| SIM moved to the other slot while running: `sim-missing`, then no data for a quarter of an hour | the provisioning session is activated at boot only; and the dial after a ModemManager restart with a connection up is refused | watchdog: `diting-modem-setup ensure-session`, then modem and ModemManager restart (device 0.7.35); stop hook below |
| No SIM in the active slot with the SIM in slot 1 | both slots are active, ModemManager takes the last one as primary (upstream) | modemmanager diting3, patch 0003 |
| Registration dropping every few minutes, `cs-domain-not-available` | voice-centric UE with CS and PS on a network without a CS domain | `usage="data" service_domain="ps-only"`, `diting-nas-pref` at boot (device 0.7.35) |
| No data for five minutes after a ModemManager restart with a connection up | the connection ends with the process; the modem treats the call as aborted and throttles PDN calls | `diting-mm-stop` as the stop hook, the watchdog dials right after a start (device 0.7.35) |
| Calls terminated after 47 s | no CS voice and no IMS | open: VoLTE |
| USB controller reset every 126 s with no host attached, one reset oopsing the kernel (2026-11-25) | `diting-hardware-recovery` took `usb0` without carrier for a stuck gadget; the Type-C data role contains "device" in both roles, and with nothing or a charger on the cable there is no carrier. A gadget left bound is bound again in the probe of the rebound controller, and that oopsed | reset only when a host has the gadget (UDC state other than "not attached"); gadget down before the reset (device 0.7.36) |

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
- **The QCA6490 has no Bluetooth address of its own**: with the generic
  NVM (`hpnv21g.bin`) it reports `00:00:00:00:5A:AD` and the kernel
  starts it unconfigured unless given one. persist holds only the
  factory Wi-Fi address (`qca6490/wlan_mac.bin`, text
  `wlan0=<12 hex digits>`), no Bluetooth one.
- **`btmgmt` hangs forever when stdin is `/dev/null`** (what a systemd
  service gets): it adds stdin to its event loop, `/dev/null` cannot be
  polled (`epoll_ctl` EPERM) and the command is never sent. Give it an
  empty pipe (`: | btmgmt ...`), as `diting-bt-setup` does.

## Deliverables

- `release/final-public/`: boot.img, vendor_boot.img, sparse
  rootfs.img, flash script, checksums. PIN 147147, first boot
  self-provisions (clock floor, firmware extraction, Bluetooth
  address into the boot partitions and at runtime, one automatic reboot).
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
- Server-built boot images (`make boot`, the release images) carry no
  Bluetooth address. After flashing them `diting-bt-setup` gives the
  controller its address at runtime, about 2 s after hci0 appears
  (`journalctl -u diting-bt-setup -b`). The address is derived from
  the factory Wi-Fi MAC and pinned in `/etc/diting/bt-address`; put an
  address of your own there to override it.

## Operational runbook

- SSH: `ssh -i ~/.ssh/diting_debug_key ubuntu@172.16.42.1` (USB) or
  the phone's Wi-Fi address. Owner images only.
- Initramfs rescue (owner images): `/dev/cu.usbmodemditing*` on the
  Mac, 115200; a root shell respawns from init-top.
  `diting.debug=hold` in `/etc/diting/cmdline` parks the boot for
  filesystem repair (`e2fsck -fy /dev/sda37` with PID 1 frozen).
- Clock behind: the phone has no usable RTC, so the clock is only as good
  as NTP, and `ntp.ubuntu.com` gets no answer on these networks
  (2026-11-27). "Automatic Date & Time" in the settings cannot change
  that. Device 0.7.37 gives systemd-timesyncd `ntp.aliyun.com` and
  `cn.pool.ntp.org` after Ubuntu's servers. Until an image with it:
  `/usr/lib/systemd/timesyncd.conf.d/10-diting-timesyncd.conf` from the
  package, then `sudo systemctl restart systemd-timesyncd`
  (`timedatectl` says `System clock synchronized: yes` about 40 s later).
- Cellular: APN for China Telecom is `ctnet` (`sudo nmcli c add type
  gsm ifname '*' con-name mobile gsm.apn ctnet autoconnect yes`, or the
  Mobile data page of Cellular Settings, 2026-11-27); the
  redial watchdog recovers hangs. A dial refused with `pdn-*-call-throttled`
  means the modem backs off for about five minutes: don't retry inside
  that. Reinstall `modemmanager` and `libmm-glib0` from the build host's
  `output/debs/` only (`packages/modemmanager/README.md`).
- NetworkManager: give the gsm connection `connection.autoconnect-retries 1`;
  otherwise every failed dial becomes twelve in a second (2026-11-24). The
  form of Cellular Settings sets it ("Dials before giving up", 1 for a new
  connection).
- Network mode: `/etc/diting/modem-mode`; the owner's phone has 3G, 4G, 5G
  with 5G preferred, `usage="data"` and `service_domain="ps-only"`. Set it
  in Cellular Settings → Network with "Keep for next boot" (passwordless
  from the desktop session; SSH is refused). **A reinstall of the rootfs
  loses the file**, and without it the network rejects the modem with
  `cs-domain-not-available` every few minutes: check `cat /etc/diting/modem-mode`
  first when the modem drops off the network (2026-11-26, KNOWN_ISSUES.md).
- ModemManager's `SetEpsUeModeOperation` (`mmcli --3gpp-set-eps-ue-mode-operation`)
  answered "successfully set" twice on 2026-11-26 and the modem did not
  change; `diting-nas-pref usage=data service-domain=ps-only` changes it
  and reads it back. Cellular Settings uses the tool.
- Voice calls need VoLTE (open); from SSH `mmcli --voice-create-call`
  works for root only.
- USB ethernet: docs/OTG.md.

## Open problems

1. **No audio** (KNOWN_ISSUES.md): the CN ADSP firmware's SPF never
   registers its GPR port; every graph operation times out. Bisect:
   did audio ever work on any boot? Decisive test: run the EEA
   firmware_mnt's adsp image with the rest CN.
2. HM6 wide camera needs a mainline sensor driver (camregs already
   built by the firmware extraction).
3. **Registration kept dropping** (2026-11-24, no longer seen after
   2026-11-25 02:15 on the owner's phone): registered for 22 s to 4 min,
   then searching for minutes, with no suspend involved. The modem was
   voice-centric with CS and PS; the network answered
   `cs-domain-not-available`. `usage="data"` and
   `service_domain="ps-only"` in `/etc/diting/modem-mode` (device 0.7.35)
   ended it: no loss on its own in 67 minutes, only a 5 to 24 s blip after
   each ModemManager start. Not isolated which of the two matters; an
   EEA SIM with CS calls and SMS was not tried in this mode.
4. **SIM moved to the other slot while running** (2026-11-25): the
   watchdog now activates the session and restarts the modem and
   ModemManager (device 0.7.35), and modemmanager diting3 reports the slot
   (patch 0003). Verified with the session removed by hand; a real tray
   swap with this version is still to do.
5. **VoLTE**: a call stays in `dialing` for 47 s and is terminated; the
   modem runs the IMS services, libqmi only queries them, and the IMS
   stack (SIP registration, call control) is in the modem firmware. The
   bearer and the modem's data service (QMI 0x302) were done by hand; the
   modem does not start the registration. See KNOWN_ISSUES.md,
   2026-11-25.
