# Kernel porting: Diting on Linux 7.2.10

Base: signed stable tag `v7.2.10`. Local branch `diting/v7.2.10` in `kernel/upstream`,
exported to `kernel/patches/` (applied with `patch -p1` onto a `git archive` export
by `scripts/prepare-kernel.sh`). Config: arm64 `defconfig` + `kernel/config/diting.config`.

## Gap analysis: upstream 7.2.10 vs. what Diting needs

| Area | Upstream 7.2.10 | Community `next` (6.17-rc1) | Diting need | Action |
| --- | --- | --- | --- | --- |
| SoC DT | `sm8450.dtsi` only, no `sm8475.dtsi` | `sm8475.dtsi` (compat overrides, eUSB2, UFS PHY, PCIe WIP, GPU hack) | SM8475 deltas | **Patch 0003**: new `sm8475.dtsi` with only binding-valid deltas (clock controllers, eUSB2 PHY, v6 UFS PHY). PCIe/GPU deltas left out. |
| Clock controllers | `qcom,sm8475-{gcc,dispcc,gpucc,camcc,videocc}` supported | same | yes | used as-is |
| TLMM | `qcom,sm8450-tlmm`, 211 GPIOs; no sm8475 compatible | `qcom,sm8475-tlmm` (not in upstream driver) | reserved GPIOs 28–31, 36–39 | use sm8450 TLMM + `gpio-reserved-ranges` (vendor `qcom,gpios-reserved`). Community DTS had TLMM **disabled** — most likely because of missing reserved ranges (accessing secure GPIOs faults). UNTESTED. |
| UFS PHY | `qcom,sm8475-qmp-ufs-phy` supported (v6 offsets, G4) | node at 0x1d80000 | yes | node in `sm8475.dtsi` |
| UFS host | `qcom,sm8450-ufshc`, freq table max 300 MHz | commented out in Diting DTS | rootfs | enabled with vendor supplies; kept the 300 MHz table (vendor uses 850 MHz; higher rates later) |
| USB HS PHY | `phy-snps-eusb2` (sm8550 compatible); no sm8475 compat in binding | `qcom,sm8475-snps-eusb2-phy` | debug USB | **Patch 0001** adds compatible to binding (falls back to sm8550) |
| eUSB2 repeater | `nxp,ptn3222` driver (simple: supplies + reset) | out-of-tree `nxp,eusb2-repeater` with tuning sequences | debug USB | use `nxp,ptn3222` at 0x4f. Vendor tuning (`qcom,param-override-seq`) not applied — may matter for signal quality. INFERRED chip identity. |
| dwc3 | flattened `qcom,sm8450-dwc3` | legacy glue + `select-utmi-as-pipe-clk` | USB2 peripheral | `dr_mode=peripheral`, `maximum-speed=high-speed`, only usb2 phy, `qcom,select-utmi-as-pipe-clk` |
| SoC match tables | `qcom,sm8450` in cpufreq-dt blocklist, UBWC, pd-mapper | n/a | avoid cpufreq-dt conflicting with cpufreq-hw | **Patch 0002** adds `qcom,sm8475` |
| CPU capacities | `sm8450.dtsi` CPU nodes carry no `capacity-dmips-mhz`, so every CPU gets 1024 and the scheduler treats the A510 as the X2 | n/a | scheduler must see A510 < A710 < X2 | **Patch 0105**: per-MHz capacities of the stock Waipio/Cape DTB (1024 / 2253 / 2386), i.e. `cpu_capacity` 277 / 832 / 1024 with the SM8475 EPSS frequencies; no power coefficients, so no energy model |
| PMICs | pm8350/b/c, pm8450, pmk8350, pmr735a dtsi | same | regulators/keys | included; regulators from vendor constraints. PM8350B L1 and PMR735B not described. |
| Reserved memory | SM8450 reference map | partial Diting fixes | must match board | Diting overrides for xbl_ramdump, xbl_sc, ADSP; rmtfs removed; ramoops at vendor location |
| Display | simplefb/simpledrm; MSM DRM supports SM8450 | simple-framebuffer only | early console | simple-framebuffer on splash. Command-mode DSC panel: **may show nothing** after ABL handoff (no autorefresh). No panel driver yet. |
| GPU (A730) | adreno 730 for SM8450 | sm8475 OPP table WIP, "hack" disabling | later | not enabled |
| PCIe0 (WLAN) | SM8450 PCIe0 description | SM8475 uses SM8550-style PCIe, WIP | WLAN | not enabled; SM8450 node stays disabled |
| Remoteprocs | ADSP/CDSP/SLPI/MPSS for SM8450 | – | audio/modem/sensors | ADSP (0016) and MPSS (0029) enabled; CDSP/SLPI not |
| IPA | none for SM8450 in 7.2 (v5.0/v5.2/v5.5 only) | vendor `ipa3` v5.1 (`qcom,ipa-hw-ver = <22>`) | mobile data | v5.1 data + SM8450 node from the XEC kernel (0030–0040, author ZXlieC, kept as-is), plus local binding compatible (0041), IRQ SPI 654 per vendor DT (0042, XEC used 655 from SM8350) and Diting enablement with `ipa_gsi_mem` (0043) |

## Patch series (`kernel/patches/`)

1. `0001 dt-bindings: arm: qcom: phy: Add SM8475 and Xiaomi Diting compatibles`
2. `0002 soc: qcom: cpufreq: Treat SM8475 like SM8450 in SoC match tables`
3. `0003 arm64: dts: qcom: Add SM8475 SoC dtsi`
4. `0004 arm64: dts: qcom: Add Xiaomi 12T Pro / Redmi K50 Ultra (diting)`

These are local experiment patches, generated with AI assistance; they are **not**
suitable for submission to Linux/postmarketOS/Nura without independent review
and re-authoring according to those projects' policies.

## Provenance of DTS constants

All from the owner's live vendor DT (`device-data/info/live.dts`), cross-checked with
the community DTS:

- regulators: `qcom,resource-name` + `regulator-min/max-microvolt` of `rpmh-regulator-*` nodes
- UFS: `ufshc@1d84000` (`reset-gpios <&tlmm 0xd2 1>`, vcc/vccq supplies, max currents), `ufsphy_mem@1d80000`
- USB: `hsphy@88e3000`, `i2c@994000/eusb2_repeater@4f`, `ssusb@a600000`
- keys: `gpio_keys/vol_up`, `pon resin`
- reserved memory: `reserved-memory` node; ramoops layout also cross-checked with
  `/sys/module/ramoops/parameters/*` on Android
- framebuffer: `splash_region` + panel timing `qcom,mdss-dsi-panel-width/height` (0x4c4 x 0xa98)
- TLMM reserved: `pinctrl@f000000 qcom,gpios-reserved`

## ABL DTB selection ids

The vendor_boot DTB section contains 14 SoC base DTBs (board-id `0 0`) and the board
data comes from `dtbo` overlays (board-id `0x10008`). ABL needs `qcom,msm-id` and
`qcom,board-id` on our DTB, but upstream bindings forbid them for SM8450-class SoCs.
They are therefore added to a copy of the DTB at boot-image time by `diting-mkbootimg`
(`fdtput`), values from the live DT: msm-id `531/540/530 0x10000`, board-id `0x10008 0`.
Whether ABL selects our DTB with these ids is **UNTESTED**.

## Build checks done (host)

- `make dtbs` W=1: no new warnings (two pre-existing `sm8450.dtsi` DSI warnings also
  appear for `sm8450-hdk`)
- `dtbs_check` (dtschema 2026.9): clean for `sm8475-xiaomi-diting.dtb`
- `dt_binding_check` for `arm/qcom.yaml`, `phy/qcom,snps-eusb2-phy.yaml`: clean
- kernelrelease check: `7.2.10-diting`

## Configuration: every filesystem built in, with binfmt_misc (driver-fix, 2026-11-26)

At the owner's request every filesystem of 7.2.10 is built into the kernel,
not a module, and `BINFMT_MISC` is on; `kernel/config/diting.config` has the
list, each group with its reason. What a mount needs is in `boot.img` alone.
The option count went from 5017 to 5203 (built in 3450 → 3655, modules
1567 → 1548); the image from 54.1 to 68.8 MB, in a 192 MiB partition.

| Group | Built in |
| --- | --- |
| local filesystems that were modules | XFS, JFS, NILFS2, GFS2 (with DLM), OCFS2, exFAT, NTFS3, HFS, HFS+, HPFS, Minix, ROMFS, cramfs, EROFS (LZ4, LZMA, DEFLATE, ZSTD), UDF, ISO9660, QNX4, QNX6, UFS, FreeVxFS, BFS, ADFS, Affs, BeFS, EFS, OMFS, JFFS2, zonefs, FUSE (so virtiofs), btrfs, overlayfs, ubifs (with UBI), CUSE |
| network | CIFS/SMB3 (SMB1 allowed), NFSv2 client, NFS server (v2–v4.2 with pNFS layouts), ksmbd, Ceph, AFS, Coda, OrangeFS, 9P (with its USB gadget transport) |
| features of what was built in | fscrypt (with the inline crypto of the UFS host), fs-verity, f2fs compression (LZO, LZ4, LZ4HC, ZSTD), the squashfs decompression mode chosen at mount, tmpfs quotas |
| characters sets | 48 NLS tables; UTF-8 is the default for FAT and exFAT and the NLS default (Chinese names on a USB stick) |
| binary formats | `binfmt_misc`; ELF and scripts were on |

Left out on purpose: `EXT2_FS` (deprecated; ext4 mounts ext2), `NTFS_FS` (the
old read-only driver; NTFS3 answers to the same `ntfs` mount type), the write
support of ADFS and UFS (marked DANGEROUS), FSCACHE and CACHEFILES (caching
for network filesystems, not filesystems), the 9P RDMA and Xen transports
(no InfiniBand, no Xen), the KUnit tests.

Nine modules were modules before and are built in as a dependency demanded it
(FUSE, the 9P stack, netfs, xts, ccm, arc4); `nvme-apple.ko` can only be a
module here.

Read on the phone on 2026-11-26 with this kernel: 21 images of 14 filesystems
mounted read-only with both files identical, among them an NTFS3, an exFAT and
an ISO9660 image with a Chinese file name, and every compression algorithm of
squashfs and EROFS; a file with a Chinese name written into and read back from
copies of vfat, exfat, NTFS3, f2fs and XFS images; squashfs with
`threads=single|multi|percpu`; a `binfmt_misc` rule by magic handing a file
to its interpreter, and the rule `systemd-binfmt` registers at boot.

**AFS does not work in this build**: it binds an IPv6 RxRPC socket when it
registers and fails at boot with `kAFS: failed to register: -97`.
`AF_RXRPC_IPV6` and `RXKAD` are needed; they are not on the phone yet.

The modules on the phone when built-ins change are another matter, met the
same day: `ubuntu-diting/ci/KERNEL.md`, "When the configuration changes".
