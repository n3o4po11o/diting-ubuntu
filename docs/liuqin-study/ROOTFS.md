# liuqin 的 rootfs：怎么构建的、里面有什么、diting 能怎么用

> 来源：`yzddmr6/xiaomipad-6pro-mainline` v0.8.0 的源码（文本副本在
> `/Users/f/work/redmi-k50ultra/liuqin-study/raw/mainline/`，下文简写 `L/`）。diting 一侧的路径
> 简写 `D/` = `diting-ubuntu/ubuntu-diting/`。标“评估”的是我的判断，不是源码里写着的。

## 1. 结论

1. **对方的 rootfs 不是 debootstrap 出来的**：基底是 Canonical 的 `ubuntu-26.04-desktop-arm64.iso`
   （4 161 089 536 字节，sha256 `c2afd538…`，`L/tools/build-liuqin-ubuntu-desktop-rootfs.sh:20-26`）
   里的 GNOME 50 桌面 squashfs，原样解出来，再在 QEMU chroot 里装 Mozilla 的 Firefox deb、7 个 apt
   包和 5–6 个 `liuqin-*` deb。
2. **整条启动链都是 liuqin 专属的**：自带的 BusyBox initramfs（带 47 个文件的哈希“契约”）、自己的
   分区名和卷标、会重划分磁盘尾部的安装器、写死 liuqin UFS 几何的槽位处理。所以**不能拿它的
   tarball 直接在 diting 上启动**。
3. **可以拿的是方法和“通用手机 / 平板上的 GNOME 调优”**：ISO 基底 + deb 集合的做法、一批与硬件
   无关的 overlay（dconf 默认值、电源键策略、时钟下限、合成器就绪后再起音频、屏幕键盘防崩、
   Firefox 迁移、相机 heap 规则等），以及它们的构建 / 测试工程实践。
4. **应用支持**：GNOME 50 + Yaru、Firefox 160（Mozilla apt）、GNOME Snapshot（软件 ISP）、
   Waydroid 只准备了内核配置、snap 支持、PipeWire + AudioReach UCM、传感器栈（libssc 0.4.4 /
   iio-sensor-proxy 3.9 / hexagonrpcd）、fprintd 指纹。没有 VA-API，浏览器硬解“暂不支持”。
5. 给 diting 的建议（评估）：**走方案 A**——在我们的构建系统里加一个 GNOME 口味，用同样的
   “固定 ISO 基底 + 现有 diting deb”做法，把通用调优项移植进 `device-xiaomi-diting`；不碰对方的
   启动链。

## 2. 构建管线

```
[0] 仓库外的输入（不在 git 里；docs/BUILD.en.md 说“从干净检出完整构建”还在准备中）
    Ubuntu ISO · tools/local/firmware-liuqin（原厂 ROM OS2.0.6.0.VMYCNXM + linux-firmware 的固件池）
    原厂 ROM 的解包与 dtbo / vendor_boot 分析 · ../linux-sm8450-liuqin @c25f056
    ../audioreach-topology @2af1f1e · fingerprint-build-inputs.tar.gz（v0.6.0 的 release 资产）
[1] build-liuqin-kernel.py            → out/kernel/{Image,dtb,modules,.config,vmlinux,build-info.json,SHA256SUMS}
[2] fetch-busybox-arm64.sh / fetch-aosp-mkbootimg.sh
[3] build-liuqin-ubuntu-desktop-rootfs.sh download|casper|extract → 桌面 rootfs + rootfs.manifest
[4] build-liuqin-wlan.py              → HSP2 WLAN 固件组合
[5] prepare-image-inputs.py run       → out/prepared-inputs/* + out/image-inputs.local.json
[6] build-liuqin-image.py             → stages: modules debs copy install assemble manifest boot
                                         runtime installer pack bundle
[7] install-liuqin.py（主机侧）       → 平板上的 RAM 安装器：重分区、写 rootfs、provision、回 fastboot
[8] --stage release-assets --device-tested → release 资产（rootfs 分卷 1900 MiB）
```

| 脚本 | 做什么 |
| --- | --- |
| `L/tools/build-liuqin-ubuntu-desktop-rootfs.sh:21-126` | 校验 ISO 的字节数和 sha256，用 `7z` 取出 `casper/minimal.squashfs` 与 `minimal.standard.squashfs`，分别哈希，`unsquashfs` 后叠成 root；拒绝 `minimal.standard.en` 层；输出带 sha256 的 `rootfs.manifest` |
| `L/tools/build-liuqin-kernel.py:44-122` | 拒绝错误的提交、脏树、或 `.config` 的 sha256 与 `L/kernel/source.json` 不符的构建；可复现环境、ccache |
| `L/tools/build-liuqin-native-root.sh:61-203` | `copy`：`cp -a` 桌面 root，断言 `snap-confine` 的 capability 还在。`debs`：QEMU chroot，流程见下 |
| `L/tools/build-liuqin-native-boot.sh`、`L/tools/lib/build-initramfs.sh:430-640` | 根契约、BusyBox initramfs（可复现 cpio）、boot 镜像；带 `INSTALLER_RUNTIME` 时加上 GNU tar、e2fsprogs、sgdisk 和安装脚本，变成安装器 |
| `L/tools/lib/rootfs-archive.sh:22-26` | GNU tar + pax，保留数字属主、ACL、全部 xattr（含 `security.capability`） |

chroot 阶段（`L/tools/build-liuqin-native-root.sh:86-166`，私有挂载命名空间，`QEMU_CPU=max,pauth-impdef=on`，
`policy-rc.d` 返回 101）依次做：

1. 清掉发行版自己的启动栈（`initramfs-tools-core`、`flash-kernel`、`linux-image-*` 等），
   清理计划先模拟，发现会连带删别的东西就中止（`L/tools/lib/root-package-policy.py:15-36`）。
2. 装 Firefox `160.0~build1`（`packages.mozilla.org` 的 deb，按 sha256 固定）并
   `glib-compile-schemas --strict`。
3. `apt-get install libqrtr1 libprotobuf-c1 gnome-snapshot libcamera-ipa gstreamer1.0-{libcamera,libav,plugins-bad,plugins-ugly} libcamera-tools v4l-utils openssh-server fake-hwclock python3-pyudev`。
4. 禁用 ssh、删除主机密钥、启用 fake-hwclock。
5. `dpkg -i` 各个 `liuqin-*` deb。

`device/configs/*.config` 是**内核** Kconfig 片段，不是 rootfs 配置。

## 3. 启动模型与分区布局

| | liuqin | diting |
| --- | --- | --- |
| 根分区 | 新建 `linux_root`（默认 32 GiB）+ `linux_home`，从 `userdata` 尾部划出；根文件系统放在分区的 `native-root/` 子目录 | `userdata` 原样使用，`LABEL=diting-root` |
| 卷标 | `LIUQIN_ROOT` / `LIUQIN_HOME` | `diting-root` |
| 启动镜像 | 自包含的 header v2 `boot.img`（gzip 内核 + 自带 initramfs + DTB），上限 192 MiB | header v4 `boot.img` + `vendor_boot.img`，initramfs-tools 生成 |
| initramfs | BusyBox，带根契约与封存检查 | Ubuntu initramfs-tools（`MODULES=list`，zstd） |
| 命令行 | 放在 `/chosen/bootargs`，**没有 `root=`**；`L/device/native-bootargs.txt` | `root=PARTLABEL=userdata ro rootwait …` |
| 槽位 | 双系统都从槽 A 启动，Android 的 boot.img 存在 `/var/lib/liuqin/switch/android/`，由 `liuqin-switch` 轮换写 `boot_a` | 直接用当前槽，不切换 |
| 固件 | deb 里 197 个固定文件 + 从 `persist` provision 的每机数据 | 首次开机从手机自己的分区提取 |
| ABL | 给原厂 dtbo 的 1781 个符号造一个“汇”节点，让 ABL 的 overlay 能套上 | 擦掉 dtbo，用 fdtput 写 id |

liuqin 的命令行：
`earlycon=simplefb keep_bootcon console=drm_log console=tty0 initcall_blacklist=simplefb_driver_init initcall_debug ignore_loglevel clk_ignore_unused rootwait panic=0 qcom_q6v5_pas.slpi_auto_boot=0 mem_sleep_default=s2idle`。
其中 `earlycon=simplefb` / `console=drm_log` / `initcall_blacklist` / `slpi_auto_boot` 是 liuqin 专属，
`clk_ignore_unused` 和 `mem_sleep_default=s2idle` 是平台级的权宜。

initramfs（`L/initramfs/init`，1537 行）做的事：把所有 `/dev/sd*` 设成只读 → 等六个 LUN 和
`boot_a boot_b persist` → `androidboot.mode=charger` 时转去关机充电模式 → 找到根分区、校验卷标
和 47 个契约文件 → `e2fsck -p` → 读写挂载 → `switch_root` 到 systemd；任何失败都重新封存存储并在
30 秒后回 fastboot。

## 4. Debian 包

版本号取自 `VERSION`（0.8.0）。从不覆盖发行版文件，用 `dpkg-divert` 改名成 `*.liuqin-orig`。

| 包 | 内容 |
| --- | --- |
| `liuqin-firmware` | 197 个固件文件（触控、QCA 蓝牙、ath11k WCN6855 及 HSP2、a730 zap / sqe / gmu、68 个 DSP 文件、VPU 固件、音频拓扑）；`preinst` / `postrm` divert 8 个发行版 ath11k 文件 |
| `liuqin-device-support` | `gnome-overlay`（除 `gdm3/custom.conf`）、发布通知器、充电策略、打过补丁的 `gnome-control-center`、自编译的 `liuqin-power-keyd` 等 |
| `liuqin-sensors` | hexagonrpcd、ssccli、打过补丁的 iio-sensor-proxy、56 个传感器配置 |
| `liuqin-kernel` | `/usr/lib/modules/<release>`、`/boot/vmlinuz-*`、`/boot/dtb-*`；initrd 只有在给了 `KERNEL_INITRAMFS` 时才带；没有维护脚本，“启动分区的更新归安装器管” |
| `liuqin-fingerprint`（可选） | 自带的 fprintd 1.94.5、FPC TOD 驱动、QSEE 客户端、RPMB supplicant、systemd 单元、polkit 规则 |
| `liuqin-device` | 元包，严格版本依赖上面各包 |

## 5. 设备专属 vs 通用

| 类别 | 内容 |
| --- | --- |
| **liuqin 硬件专属** | `liuqin-firstboot.config` / camera / fingerprint / keyboard 内核片段；背光 `ktz8866-backlight`（max 2047）；触摸板规则；音频拓扑与 UCM `Xiaomi-Pad-6-Pro`；WLAN MAC（PCI id 17cb:1103）；MiPPS 认证；充电模式；`liuqin-switch` 与 KernelSU 模块；initramfs、安装器、ABL 工具、槽位辅助程序；dconf 的 `scaling-factor=2`（11 寸面板）；传感器挂载矩阵；相机 softdep 的模块名 |
| **通用的 GNOME-on-mobile 调优** | dconf 默认值与锁（息屏 300 s、电池 15 分钟挂起、启用 OSK）；GDM 与用户 profile；**电源键策略**（`liuqin-power-keyd` + logind `HandlePowerKey=ignore` + 设置面板补丁，需要 `pmic_pwrkey` 和唤醒源 `qcom-battmgr-charge`）；时钟下限 / fake-hwclock；BlueZ `AutoEnable`；合成器就绪后再起 PipeWire 的 drop-in；GNOME Shell 50 触摸事件空指针的防护扩展；IBus 键盘布局包装脚本；snap 准入；Firefox 迁移；相机 DMA-BUF heap 规则与 Snapshot 包装器；传感器服务重新宣告后重启代理的单元和 polkit 规则；发布通知器；devmode 的 USB NCM + 仅密钥 SSH |
| **两者兼有** | `50-liuqin-dmabuf.conf`（`GDK_DISABLE=dmabuf`、`WEBKIT_DISABLE_DMABUF_RENDERER=1`，针对 Adreno 730 的缓存一致性变通，评估：diting 很可能也需要，未测）；`liuqin-physical-platform`（盖住 Gunyah 虚拟化节点，同 SoC）；充电策略脚本在三块板之间共用，diting 需要加一项；BT 公共地址的思路通用但路径是 liuqin 的 |
| **纯构建 / 安装工具** | 全部 `tools/`、`tests/`、`liuqin-rom-images.json`、GCC 的“关于”页作者补丁 |

## 6. 应用支持清单

| 领域 | 来源与版本 | 是否绑定 liuqin 硬件 |
| --- | --- | --- |
| 桌面 | ISO 自带 GNOME Shell 50 + Yaru；dock 收藏了安装器、Firefox、Evolution、Nautilus、Rhythmbox、LibreOffice、Snap Store、Yelp、Thunderbird | 否 |
| 显示管理器 | gdm3；镜像里没有账户也不自动登录，首次开机走 gnome-initial-setup | 否 |
| GNOME 设置 | Ubuntu `1:50.0-0ubuntu6` 源码 + 两个补丁（电源键策略行、关于页作者） | 否 |
| 屏幕键盘 | GNOME 自带 OSK（dconf 启用）+ `liuqin-osk-guard` 扩展 | 否 |
| 浏览器 | Mozilla apt 的 `firefox_160.0~build1_arm64`；Mozilla 源 pin 1000，Ubuntu 的 firefox 降到 -1；没有用户数据时卸掉 snap。没有任何视频相关偏好 | 否 |
| 视频 | 无 VA-API；`gstreamer1.0-libav`（软解）、plugins-bad（`h264parse`）；H.264 硬解靠 GStreamer 的 `v4l2h264dec` | 内核 iris |
| 相机 | `gnome-snapshot`、`libcamera-ipa`、`gstreamer1.0-libcamera`、libcamera-tools、v4l-utils；软件 ISP | 内核 CAMSS + S5KJN1 |
| Waydroid | 没装，只准备了内核配置（binder、binderfs、策略路由） | 仅内核配置 |
| snap | ISO 自带的 snapd；FUSE 内建，squashfs xattr，AppArmor 进 LSM 列表 | 仅内核配置 |
| 音频 | ISO 的 PipeWire / WirePlumber + 就绪 drop-in；UCM `sm8450/Xiaomi-Pad-6-Pro`，源码构建的 AudioReach 拓扑 | 是 |
| 网络 | ISO 的 NetworkManager / BlueZ；devmode 的 NCM + SSH | MAC / 地址辅助程序是 |
| 传感器 | libssc 0.4.4、iio-sensor-proxy 3.9（7 个项目补丁 + 共享修复）、hexagonrpcd 0.5.0 | 配置路径和矩阵是；补丁通用 |
| 指纹 | fprintd / libfprint + FPC1264 TOD 驱动 | 全部 |
| 电源 UI | UPower `qcom-battmgr`、充电指示器扩展、采样器、MiPPS 认证 | 是（sysfs 名） |

对照 diting：我们的 Phosh 口味在传感器上用的是同一个 libssc 提交和 iio-sensor-proxy 3.9
（`D/config/diting.conf:86-88`），对方的 iio-sensor-proxy 补丁大概率能套上（评估，未试）。Firefox
我们用的是 Ubuntu 的 `firefox 160.0.1~build1` deb 加 `mobile-config-firefox` 和强制硬解的偏好，
比对方多了浏览器硬解。

## 7. diting 怎么用这个 rootfs：三个选项（评估）

**A. 移植方法，保留 diting 的启动模型（推荐）。** `D/config/diting.conf:19-21` 已经有
`ROOTFS_DESKTOP`（空 / `phosh` / `phosh-full`）的开关；再加一个 GNOME 口味，用固定 ISO 当基底，
在 QEMU chroot 里装现有的 diting deb，把 §5 的“通用调优”移植进 `device-xiaomi-diting`。全程不碰
对方的启动链。

**B. 移植 tarball。** 作为快速实验可行，残留风险中等。步骤：

1. 合并 `rootfs.tar.gz.part-NN`，核对 `SHA256SUMS`，用 GNU tar 保留 xattr 和 capability 解开。
2. 在 arm64 chroot 里 purge `liuqin-device liuqin-fingerprint liuqin-kernel liuqin-sensors liuqin-firmware liuqin-device-support`，
   删掉 dpkg 之外建的单元链接（`L/tools/build-liuqin-native-root.sh:246-255`）、`/etc/liuqin-*`、
   `/etc/flash-kernel`、`/var/lib/liuqin-*`。
3. 重装 `initramfs-tools`，先装 `device-xiaomi-diting`，再装 `linux-image-7.2.10-diting`，让启动镜像
   钩子生效。
4. 改 `/etc/fstab`、主机名、`machine-info` 的机箱类型、dconf，`dconf update`。
5. 打成卷标 `diting-root` 的 ext4 镜像，配 diting 自己的 boot / vendor_boot 刷入。
6. 检查 diting 内核的桌面需求：AppArmor 默认 LSM、squashfs xz / lzo / xattr、FUSE。

**必须在首次启动前拆掉的隐患**：`liuqin-gnome-storage-guard` 被 `basic.target` 依赖，找不到它的
标记文件就把 `/` 重新挂成只读；WLAN 和 BT 的服务 `Requires=` 那些没有 `/var/lib/liuqin-private/*`
就失败退出的辅助程序。

**C. 整体采用对方的安装器、initramfs 和槽 A 轮换。** 不建议：它假定 35 个分区的原厂 GPT、liuqin
的 ROM 固定值、`/dev/sde` 几何和 KernelSU 的 KMI。

必须替换的设备绑定项：内核与模块、`/lib/firmware`（197 个文件和 8 个 divert）、全部 `liuqin-*` 包、
UCM 与拓扑、触控板 / fastrpc / mipps 的 udev 规则、背光名和缩放、分区名 / 卷标 / GPT 常量、命令行、
ABL id（liuqin 是 `xiaomi,miboard-id <0x10 0>`）、传感器配置和注册表、从 `persist` 取的 MAC / 蓝牙
地址 / 校准数据、主机名和品牌信息。

可以原样拿的：dconf 默认值与锁（缩放要改）、电源键策略那一套、时钟下限、dmabuf 变通（先测）、
合成器就绪后的音频、osk-guard、键盘布局包装、snap 准入、Firefox 迁移、相机 heap 规则和 Snapshot
包装器、传感器重新宣告的单元和 polkit 规则、iio-sensor-proxy / libssc 补丁。

## 8. 值得借鉴的工程实践

1. 固定 ISO + 带哈希的整树清单，下一阶段再校验一遍
   （`L/tools/build-liuqin-ubuntu-desktop-rootfs.sh:31-126`、`L/tools/build-liuqin-native-root.sh:33,49-52`）。
2. 内核锁：提交、config sha256、片段哈希，`flock` 下写 `build-inputs.json`
   （`L/kernel/source.json`、`L/tools/build-liuqin-kernel.py:55-98`）。
3. 按内容指纹缓存慢的 QEMU 构建，命中后复核 sha256（`L/tools/prepare-image-inputs.py:65-124`）。
4. 快的 QEMU chroot（`pauth-impdef=on`）、挂载命名空间隔离、`policy-rc.d`、apt 列表缓存
   （`L/tools/build-liuqin-native-root.sh:48,111-114,177-186`）。
5. 保留 capability 的归档，并在复制、打包、安装三处断言 `snap-confine` 的 capability 还在。
6. 根契约生成器拒绝固定发行版自有的路径——固定了它们，`apt upgrade` 就会变成启动失败
   （`L/tools/lib/build-root-contract.py:149-241`）。
7. `dpkg-divert` 加上 `prerm` 里按版本号决定是否停用旧单元。
8. 先模拟、发现连带删除就拒绝的启动栈清理。
9. 发布闸门：`bundle.json` 记录哈希和提交，安装器文件变过就要 `--device-tested`。
10. 安装器的安全措施：全盘只读姿态、`boot_id` 与序列号绑定、GPT 备份、保留 `/home` 时的 UID / GID
    冲突检测。
11. 36 个测试文件：ARM64 overlay 里的 deb 升级与回滚、1550 行的 initramfs 变异测试、合成磁盘上的
    分区布局测试、传感器构建里的负对照和 `DT_NEEDED` 闭包审计、QEMU 冒烟检查。
12. 经过校验的设备树手术（符号汇 + 解包比对 boot 镜像）；KernelSU 补丁器必须先复现原厂字节再改动。

## 9. 报告里发现的对方问题

- 依赖全靠 `dpkg -i`：没有任何步骤 `apt install` `fprintd`、`libfprint`、`libpam-fprintd`、`zenity`、
  `iio-sensor-proxy`，只能靠 ISO 里碰巧有。
- live 会话的残留（casper、安装器）大概率还在，dock 收藏里仍有安装器。
- 仓库里的 `L/device/firmware/firmware.manifest:115` 的拓扑哈希与构建器固定值不一致。
- 只有 256 GB 的双系统布局在真机上装过。
