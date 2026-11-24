# Decisions

| # | Decision | Status | Reason |
| --- | --- | --- | --- |
| D1 | Workspace root is `~/linux-diting` (owner's existing dir with CLAUDE.md), not `~/diting-ubuntu` | accepted | CLAUDE.md: preserve the owner's workspace |
| D2 | Kernel base: signed stable tag v7.2.10 + local patches; community `next` (6.17-rc1) is reference only | accepted | kernel policy |
| D3 | Kernel source exported with `git archive` + `patch`, built out-of-tree in `work/` | accepted | no `.git` → no SCM suffix, `kernelrelease` = `7.2.10-diting` exactly; stale-tree detection via a digest of lock+patches+fragment |
| D4 | Write a reduced `sm8475.dtsi` instead of copying the community one | accepted | community file has PCIe WIP, a "[hack]" GPU/UFS commit and a non-upstream TLMM compatible |
| D5 | TLMM enabled with `gpio-reserved-ranges` instead of disabled | accepted (UNTESTED) | vendor DT lists the secure GPIOs; UFS reset needs TLMM 210 |
| D6 | eUSB2 repeater as `nxp,ptn3222` (upstream driver) | accepted (INFERRED chip) | same I2C address/supplies/reset; vendor tuning sequence not supported upstream |
| D7 | `qcom,msm-id`/`qcom,board-id` added with `fdtput` at image time, not in DTS | accepted | upstream schema forbids them on SM8450-class; ABL needs them |
| D8 | Boot image = header v4 boot.img (kernel only) + vendor_boot.img (DTB, initramfs, cmdline) | accepted | measured stock layout; same as pmOS boot-deploy for v3/v4 |
| D9 | Vendor dtbo is cleared by the owner with `fastboot erase dtbo` (after backup); no placeholder dtbo generated | accepted (owner instruction) | ABL would otherwise apply vendor overlays to the mainline DTB |
| D10 | No slot switching for tests | accepted | slot A has empty vendor_boot/dtbo and older bootloader firmware |
| D11 | Uncompressed `Image` in boot.img, no appended DTB | accepted | stock kernel is an uncompressed Image; DTB lives in vendor_boot for v4 |
| D12 | Kernel debs via upstream `make bindeb-pkg` (`linux-image-7.2.10-diting`, headers, libc-dev); DTBs shipped inside linux-image | accepted | standard Debian/Ubuntu kernel layout; no separate dtb package needed |
| D13 | `device-xiaomi-diting` builds boot images on the device in `/boot/diting/` from kernel postinst / initramfs post-update hooks; never flashes | accepted | Ubuntu-native kernel updates without pmOS tooling; flashing stays manual |
| D14 | Ubuntu initramfs-tools with `MODULES=list` and built-in storage/USB drivers | accepted | keeps vendor_boot ≤ 96 MiB; root mount does not depend on module loading |
| D15 | Debug: `diting.debug=hold/usb` → USB NCM + ACM root shell + dmesg to pstore pmsg; ramoops identical to vendor layout | accepted | logs readable from Android `/sys/fs/pstore` after a warm reboot; no UART available |
| D16 | rootfs via `debootstrap` (gutsy script) from ports.ubuntu.com, deb822 sources with Signed-By | accepted | Debian trixie debootstrap has no `resolute` script; all Ubuntu suites share gutsy |
| D17 | No root partition chosen; rootfs is an image file only | accepted | no safe partition approved by the owner yet |
| D18 | Locked user, key-only SSH, NOPASSWD sudo for that user, host keys generated on first boot | accepted | no passwords baked in; access only over local USB |
| D19 | `pmbootstrap` not used | accepted | layout is fully known; mkbootimg + fdtput suffice |
| D20 | Docker not used | accepted | native arm64 host |
| D21 | EAS (energy-aware scheduling) is not enabled; the CPU nodes get no `dynamic-power-coefficient` | not for now (owner, 2026-11-24) | measured: under 1 % of the idle draw to gain in standby, against a responsiveness risk; see "D21: EAS" below |
| R1 | Copy downstream DT nodes / vendor drivers | rejected | policy |
| R2 | Use `/dev/sda28` (super) or any raw path for root | rejected | unverified, destructive |
| R3 | Use community 6.17-rc1 kernel as deliverable | rejected | kernel policy |

## D21: EAS — not for now (2026-11-24)

Decided by the owner after the CPU capacity patch (0105). Revisit only if battery drain
with the screen on turns out to be a problem.

**What it would do.** With capacities alone the scheduler knows which CPU is faster and
moves heavy threads up, but at wakeup it still picks the previous CPU or an idle neighbour
without looking at power. EAS estimates the energy of every cluster for the waking task and
picks the cheapest one (`find_energy_efficient_cpu()`), as long as no CPU is overutilized.
It saves energy; it does not make anything faster.

**What it would take.** One property per cluster in `sm8450.dtsi`, the values of the stock
Cape DTB: `dynamic-power-coefficient = <100>` (cpu0-3), `<257>` (cpu4-6), `<509>` (cpu7).
No OPP table is needed: `qcom-cpufreq-hw` registers the energy model through
`dev_pm_opp_of_register_em()` as soon as the property exists, and
`dev_pm_opp_calc_power()` takes the voltage of each OPP from the hardware LUT:
P = coefficient × mV² × MHz. Until then the registration fails silently (debug level),
which is why `/sys/kernel/debug/energy_model` is empty.
`/proc/sys/kernel/sched_energy_aware` switches EAS at runtime, so a test needs one flash
and no further rebuilds.

**The model, with this unit's OPP voltages** (dynamic power of one core):

| | A510 | A710 | X2 |
| --- | --- | --- | --- |
| lowest OPP | 300 MHz @ 0.580 V → 10 mW | 634 MHz @ 0.604 V → 59 mW | 787 MHz @ 0.584 V → 137 mW |
| highest OPP | 2016 MHz @ 0.856 V → 148 mW | 2746 MHz @ 0.940 V → 623 mW | 3187 MHz @ 0.992 V → 1596 mW |

By the `capacity-dmips-mhz` numbers, the same work costs 1.27× the energy on an A710 and
2.21× on the X2 compared with an A510, all at their lowest OPP.

**Measured, which is why it is deferred.** Screen off, at the greeter, a 30 s window with
nothing running in it: cpu0-3 were busy 1.21 s and cpu4-7 0.38 s. CPU time is small (5 % of
one core) and 24 % of it lands on the big cores. The idle draw with the screen off, read the
same evening before the capacity patch, was 325 mA at 4.16 V, about 1.35 W (one reading).
That big-core time is worth roughly 1–6 mW averaged over the window, and doing the same
work on the A510 cluster would still cost part of it: well under 1 % of the idle draw.
The unmeasured case is screen-on light use (chat, browsing, music), where there is much more
CPU time to place.

**Costs.**
- Medium tasks are deliberately kept on the slower cores as long as they fit there, which
  can be felt as a less responsive UI.
- The model covers dynamic power only, not waking a cluster or its idle states.
- The window where EAS acts is narrow: a CPU is overutilized once its utilization exceeds
  its capacity, so a little core that is fully busy above ~545 MHz switches EAS off for the
  whole system until the load balancer resolves it.

**If it is revisited:** add the three properties, flash `vendor_boot` only (the kernel binary
does not change), and compare the battery current
(`/sys/class/power_supply/qcom-battmgr-bat/current_now`) with
`/proc/sys/kernel/sched_energy_aware` at 0 and 1.
