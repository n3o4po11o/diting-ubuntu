# 全盘加密：cryptsetup / LUKS2，开机用屏幕键盘解锁

状态：**设计文档，尚未实施**。里面的“现状”都是 2026-11-26 在手机上和源码树里读出来的
（内核为 AFS 版，`68,901,376` 字节；系统 Ubuntu 26.04.1 LTS，代号 resolute）；没有读过的地方
标了“待核实”。实施前先读第 10 节的待核实清单。

目录：[0 结论](#0-结论) · [1 现状](#1-现状已核实) · [2 目标架构](#2-目标架构) ·
[3 内核选项](#3-内核选项) · [4 用户态](#4-用户态) · [5 LUKS 参数](#5-luks-与-crypttab-参数) ·
[6 安装方式](#6-安装方式) · [7 测试计划](#7-测试计划) · [8 安全属性与限制](#8-安全属性与限制) ·
[9 性能](#9-性能) · [10 待核实与风险](#10-待核实与风险) · [11 出处](#11-出处)

## 0 结论

- **内核只差 2 个选项**：触摸屏驱动和它的 SPI 控制器现在是模块，而模块在还没解锁的根分区上，
  开机解锁时拿不到，要改成内建：`TOUCHSCREEN_ST_FTM5_SPI=y`、`SPI_QCOM_GENI=y`。
  dm-crypt 这一栈（`BLK_DEV_DM`、`DM_CRYPT`、`DM_INTEGRITY`、AES-XTS）已经全部内建。
- **屏幕键盘用 `unl0kr`**，不是 osk-sdl：Ubuntu 26.04 的仓库里有 `unl0kr 3.4.2`，没有 osk-sdl。
  Phosh 自己当不了解锁界面（它在加密的根分区上），解锁界面是 initramfs 里的 unl0kr。
- **用户态装三个包**：`cryptsetup`、`cryptsetup-initramfs`、`unl0kr`；在 `/etc/crypttab` 里给
  根分区加上 `keyscript=/usr/share/initramfs-tools/scripts/unl0kr-keyscript`，再
  `update-initramfs -u`。这是 Ubuntu 软件包自带的接入方式。
- **启动参数要改**：`root=PARTLABEL=userdata` 变成 `root=/dev/mapper/diting-root`，并且
  `scripts/build-release.sh` 里检查这条参数的那一行也要跟着改。
- **可选**：把 SoC 的硬件加密引擎改成内建（`CRYPTO_DEV_QCE=y`）。它现在是模块，解锁阶段
  用不上；内建后解锁阶段也能用上它（dm-crypt 请求 `xts(aes)` 时按注册优先级会选中它，
  还没有实测）。UFS 的内联加密引擎 dm-crypt 用不了。
- **风险先说清**：bootloader 解锁、没有验证启动，initramfs 是明文可改的，所以挡不住能物理
  接触手机的人；口令丢了数据就没了。详见第 8 节。

## 1 现状（已核实）

### 1.1 启动链

| 环节 | 现状 |
| --- | --- |
| 引导 | ABL 读 `boot_a`（内核，192 MiB 分区）和 `vendor_boot_a`（Ubuntu initramfs + DTB + 内核命令行，96 MiB 分区），不读根分区上的 `/boot` |
| initramfs | `/boot/initrd.img-7.2.10-diting`，20,941,683 字节（zstd）；镜像里那份 20,678,557 字节 |
| 根分区 | `/dev/sda37`，`PARTLABEL=userdata`，223.6 GiB，ext4，卷标 `diting-root`，UUID `8257a8d7-fee6-4fca-86ef-32261e81ce6d` |
| 内核命令行 | `console=tty0 earlycon fw_devlink.sync_state=timeout root=PARTLABEL=userdata ro rootwait allow_mismatched_32bit_el0 diting.debug=usb`，其后是 ABL 自己追加的一段（`bootinfo.*`、`loglevel=6` 等） |
| `/etc/diting/cmdline` | `root=PARTLABEL=userdata ro rootwait diting.debug=usb allow_mismatched_32bit_el0`；由 `scripts/build-rootfs.sh` 第 143 行写入 |
| `/etc/fstab` | `LABEL=diting-root  /  ext4  defaults,noatime,x-systemd.growfs  0  1`；由 `scripts/build-rootfs.sh` 第 241–245 行写入 |

命令行是怎么拼出来的：`BOOT_CMDLINE_BASE`（`config/diting.conf`）+ `DITING_ROOT_CMDLINE`
（同文件，第 62 行的默认值就是上面那串）；手机上的钩子 `zz-diting-bootimg` 调
`diting-mkbootimg --release`，后者把 `/etc/diting/cmdline` 接在 `BOOT_CMDLINE_BASE` 后面。
公开镜像不带 `diting.debug`（`build-rootfs.sh` 第 137–139 行会把它去掉，理由是那个 USB 串口
shell 不需要登录）。

### 1.2 initramfs 的配置和内容

- `/etc/initramfs-tools/initramfs.conf`：`MODULES=most`、`COMPRESS=zstd`、`BUSYBOX=auto`。
  但设备包的 `/etc/initramfs-tools/conf.d/diting` 覆盖成 **`MODULES=list`**、`COMPRESS=zstd`、
  `BUSYBOX=y`。`list` 意味着只装显式列出的模块——现在的 initramfs 里只有 `fuse.ko` 一个。
- 内容：538 项。有 busybox、udev、Plymouth（109 项，主题是基础镜像留下的
  `ubuntu-budgie-logo`/`ubuntu-budgie-text`，以及 `text`、`details`）、`dmsetup`、
  `libevdev`。**没有** cryptsetup、没有任何屏幕键盘、没有 SDL。
- 设备包自己的脚本：
  - `init-top/diting-debug`：命令行里有 `diting.debug=` 时，起 USB NCM gadget，并在
    `/dev/ttyGS0` 上开一个不需要登录的 shell；`diting.debug=hold` 则停在这里不挂根分区。
    这个 shell 在解锁之前就有，可以当恢复入口（第 6 节）。
  - `init-bottom/diting-debug`：收尾。
  - `hooks/diting`：把 `diting-usb-gadget`、`ip`、`setsid`、`diting-reboot-bootloader`
    和 klibc 的 `dd` 放进 initramfs。

### 1.3 存储和硬件

| | |
| --- | --- |
| UFS 盘 | `/dev/sda`，235.5 GiB；逻辑块和物理块都是 4096 字节；I/O 调度器 `none` |
| TRIM | 支持：`lsblk -D` 给出 `DISC-GRAN 4K`、`DISC-MAX 32G` |
| 内存 | 10,365 MB |
| TPM | 没有（`/sys/class/tpm` 下没有设备）——只能用口令，做不了自动解锁 |
| 显示（开机初期） | `DRM_SIMPLEDRM=y`，画面是引导程序留下的 splash 缓冲 |
| 触摸屏 | 设备树 `&spi4 { touchscreen@0 { compatible = "st,ftm5-spi"; ... } }`；中断 TLMM 21，复位 TLMM 20，`vdd-supply = <&vreg_l2c_1p8>`，`avdd-supply = <&ts_avdd>`（TLMM 71 上的固定稳压器，启动延时 2 ms） |

### 1.4 加密相关的软件包（Ubuntu 26.04 仓库里的情况）

| 包 | 仓库里 | 手机上 |
| --- | --- | --- |
| `cryptsetup`、`cryptsetup-bin` | `2:2.8.4-1ubuntu4` | 没装 |
| `cryptsetup-initramfs` | `2:2.8.4-1ubuntu4` | 没装 |
| `cryptsetup-ssh` | `2:2.8.4-1ubuntu4` | 没装 |
| `systemd-cryptsetup` | `259.9-0ubuntu0.1` | 没装 |
| `unl0kr` | `3.4.2+dfsg-1` | 没装 |
| `osk-sdl` | **不在仓库里** | — |
| `plymouth`、`plymouth-theme-spinner` | `24.004.60+git20250831.4a3c171d-0ubuntu8` | 已装 |

## 2 目标架构

```
ABL ─ boot_a: kernel ─ vendor_boot_a: initramfs + DTB + cmdline
      │
      ├ udev 起来，触摸屏（内建）出现，simpledrm 在 splash 缓冲上
      ├ scripts/local-top/cryptroot：等 PARTLABEL=userdata，调 keyscript
      │     └ unl0kr-keyscript：屏幕键盘 → 口令 → cryptsetup open
      │           → /dev/mapper/diting-root
      ├ scripts/local：root=/dev/mapper/diting-root，挂载
      └ systemd → Phosh 正常启动
```

- **加密范围**：`sda37` 整个分区是一个 LUKS2 容器，头部就在分区里，不单独放。其余分区
  （Android 的 system/vendor/cust/modem 等）不动。
- **不加密的部分**：内核、initramfs、命令行都在 `boot_a`/`vendor_boot_a` 里，是明文——ABL
  不可能从加密介质引导。
- **fstab**：根变成 `/dev/mapper/diting-root`（或里面 ext4 的 UUID），`x-systemd.growfs`
  照常把文件系统撑满整个映射设备。
- **和 always-online 的关系**：手机不自动挂起，所以不存在“挂起时密钥留在内存”的问题；
  `luksSuspend` 是可选项，不在这份计划里。

## 3 内核选项

### 3.1 已经内建，不用动

`BLK_DEV_DM=y`、`DM_CRYPT=y`、`DM_INTEGRITY=y`（LUKS2 带校验的模式要用）、`DM_VERITY=y`、
`CRYPTO_AES=y`、`CRYPTO_XTS=y`、`CRYPTO_CBC=y`、`CRYPTO_CTR=y`、`CRYPTO_ESSIV=y`、
`CRYPTO_HMAC=y`、`CRYPTO_SHA256=y`、`BLK_DEV_LOOP=y`、`KEYS=y`、`INPUT_EVDEV=y`、
`INPUT_TOUCHSCREEN=y`、`DRM_SIMPLEDRM=y`、`FRAMEBUFFER_CONSOLE=y`、`VT=y`、
`QCOM_GENI_SE=y`、`PINCTRL_SM8450=y`、`REGULATOR_QCOM_RPMH=y`、`REGULATOR_FIXED_VOLTAGE=y`。

`CRYPTO_XTS` 是文件系统那一轮才变成内建的，之前是模块 `xts.ko`：那时 initramfs 里没有它，
aes-xts 在解锁阶段用不了。

### 3.2 要改的两个

| 选项 | 现在 | 改成 | 为什么要内建 |
| --- | --- | --- | --- |
| `TOUCHSCREEN_ST_FTM5_SPI`（`st-ftm5.ko`） | `m` | `y` | unl0kr 靠 libinput 读触摸屏；initramfs 是 `MODULES=list`，这个模块不在清单里，而且它在没解锁的根分区上 |
| `SPI_QCOM_GENI`（`spi-geni-qcom.ko`） | `m` | `y` | 触摸屏挂在 GENI SPI 控制器上；依赖的 `QCOM_GENI_SE`、pinctrl、稳压器都已内建 |

它依赖的稳压器（`vreg_l2c_1p8` 来自 RPMh，`ts_avdd` 是固定稳压器）都已内建。

**不改内核的替代办法**：在设备包里把 `spi_geni_qcom` 和 `st_ftm5_spi` 写进
`/etc/initramfs-tools/modules`。能用，但解锁就依赖 initramfs 里带着这两个模块文件；内建更稳，
也符合“能内建就内建”。

### 3.3 可选：硬件加密

- **SoC 加密引擎（QCE）**：设备树 `sm8450.dtsi` 里有 `crypto@1dfa000`
  （`qcom,sm8450-qce`），当前内核里已经注册了它的 AES-XTS 实现：`xts-aes-qce`，优先级 275，
  模块名 `qcrypto`（`CRYPTO_DEV_QCE=m`）。dm-crypt 默认的 `aes-xts-plain64` 请求的是
  `xts(aes)`，按注册情况会选中它——这是从 `/proc/crypto` 读出来的，还没有实际跑过 dm-crypt。
  但它是模块，解锁阶段（`MODULES=list`）没有它。要开机就走硬件，改成 `CRYPTO_DEV_QCE=y`。
  是不是比软件快，没测过（第 9 节）。
- **UFS 内联加密引擎（ICE）**：`QCOM_INLINE_CRYPTO_ENGINE=y`，块层已经登记了它的能力
  （64 个密钥槽，`raw_keys: supported`）。但这个内核的 dm-crypt 不经过块层加密
  （`dm-crypt.c` 里没有 `blk_crypto`），所以**全盘加密用不上它**；能用的只有 fscrypt
  （`FS_ENCRYPTION_INLINE_CRYPT=y`）。fscrypt 是另一种方案，见 3.4。
- **ARMv8 加密扩展**：`CRYPTO_AES_ARM64_CE_BLK=y`。当前 `/proc/crypto` 里名为 `aes` 的实现
  只有 `aes-lib`，没有单独的 `aes-arm64` 驱动；扩展指令是否已经在 `aes-lib` 背后生效，待核实。
- `CRYPTO_USER_API`（AF_ALG）是模块或关着，不需要：Ubuntu 的 cryptsetup 用自己的库做
  Argon2 和 PBKDF。

### 3.4 fscrypt 作为对照

fscrypt 现在已内建，还能走 UFS 的内联加密引擎。但它是目录级加密：没有开机口令、文件名和
元数据的保护方式不同、密钥管理在用户态。它不等于全盘加密，只是说明“硬件加速 + 加密”在这台
机器上另有一条路。密钥能不能通过 TrustZone 写进 ICE，没有试过。

### 3.5 改配置之后必须做的事

模块和内核必须来自同一份配置。规则和工具在 `ubuntu-diting/ci/KERNEL.md` 的
“When the configuration changes”一节：`scripts/module-diff.py` 比对，再在手机上跑
`scripts/phone-modules-sync.sh`（这次会移走 `st-ftm5.ko`、`spi-geni-qcom.ko`，
如果 QCE 也内建，还有 `qcrypto.ko`）。

## 4 用户态

### 4.1 要装的包

```
sudo apt install cryptsetup cryptsetup-initramfs unl0kr
```

- `cryptsetup-initramfs` 依赖 `busybox-initramfs`、`cryptsetup`、`initramfs-tools`，
  推荐 `console-setup`、`kbd`、`plymouth`。
- `unl0kr` 依赖 `libdrm2`、`libinih1`、`libinput10`、`libudev1`、`libxkbcommon0`，
  以及 `cryptsetup-initramfs`。

设备包（`packages/device-xiaomi-diting`）应该把这几个加进依赖，镜像里才带着。

### 4.2 cryptsetup-initramfs 做了什么

它装进系统的文件：

| 文件 | 作用 |
| --- | --- |
| `/usr/share/initramfs-tools/hooks/cryptroot` | 生成 initramfs 时，把根文件系统需要的 crypttab 条目、cryptsetup 程序和库、keyscript 写进去 |
| `/usr/share/initramfs-tools/scripts/local-top/cryptroot` | 开机时等源设备出现，调 keyscript 或 `cryptroot-unlock` 拿口令，`cryptsetup open`；失败后在 `local-block` 阶段继续试 |
| `/usr/share/initramfs-tools/scripts/local-block/cryptroot` | 设备来晚了的第二次机会 |
| `/usr/share/initramfs-tools/scripts/local-bottom/cryptroot` | 根挂上之后，不再需要的映射在这里处理 |
| `/usr/share/cryptsetup/initramfs/bin/cryptroot-unlock` | 在控制台或 Plymouth 上问口令的程序 |
| `/etc/cryptsetup-initramfs/conf-hook` | 生成 initramfs 时的钩子（例如 `KEYFILE_PATTERN`） |
| `/usr/share/initramfs-tools/conf-hooks.d/cryptsetup` | 配置钩子 |

**哪些条目会进 initramfs**：根文件系统所在的设备、`/usr`、挂起用的交换设备，以及带
`initramfs` 选项的条目。根在 `/dev/mapper/diting-root` 上时，对应条目自动入选。

**重试次数**：`tries` 选项，默认 3（脚本里 `maxtries="${CRYPTTAB_OPTION_tries:-3}"`）。

**keyscript 得到的环境变量**（从 `scripts/local-top/cryptroot` 里读出来的）：`CRYPTTAB_NAME`、
`CRYPTTAB_SOURCE`、`CRYPTTAB_KEY`、`CRYPTTAB_OPTIONS`、`CRYPTTAB_OPTION_<选项名>`、
`CRYPTTAB_TYPE`。unl0kr 的手册页还提到它用 `CRYPTTAB_TRIED`（已经试了几次）。
它把口令写到标准输出；其它信息写标准错误。它会被放在 initramfs 的
`/lib/cryptsetup/keyscripts/` 下。

**`/etc/crypttab` 的格式**（Debian/Ubuntu 的 initramfs-tools 实现）：

```
<映射名>  <源设备>  <密钥文件或 none>  <选项>
```

源设备可以写 `/dev/...`、`UUID=`、`LABEL=`、`PARTUUID=`、`PARTLABEL=`。选项（手册页里的原名）：
`cipher=`、`size=`、`sector-size=`、`hash=`、`offset=`、`skip=`、`keyfile-offset=`、
`keyfile-size=`、`keyslot=`、`header=`、`verify`、`readonly`、`tries=`、`discard`、`luks`、
`plain`、`same-cpu-crypt`、`submit-from-crypt-cpus`、`no-read-workqueue`、
`no-write-workqueue`、`swap`、`tmp`、`check`、`checkargs=`、`initramfs`、`noearly`、`noauto`、
`loud`、`quiet`、`keyscript=<路径>`。注意这里用连字符（`no-read-workqueue`），
和 systemd 自己的 crypttab 实现不是一套。

内核命令行上也可以用 `cryptopts=target=<名>,source=<设备>,...` 临时指定，initramfs 里
带的 crypttab 优先够用。

### 4.3 unl0kr

- **原理**：LVGL 画到 DRM 帧缓冲上，不用 GPU；输入靠 libinput（udev）。
- **装进系统的文件**：`/usr/bin/unl0kr`、`/etc/unl0kr.conf`、
  `/usr/share/initramfs-tools/hooks/unl0kr`、
  `/usr/share/initramfs-tools/scripts/unl0kr-keyscript`。
- **keyscript 的全文**（去掉注释）：

  ```sh
  if [ -z "${CRYPTTAB_SOURCE}" ] || [ -z "${CRYPTTAB_NAME}" ]; then
      echo "This is a crypttab keyscript script, don't run directly." 1>&2
      exit 1
  fi
  plymouth hide-splash 2>/dev/null
  ttymode=$(stty -g)
  stty -echo -icanon min 0 time 0
  unl0kr -n
  stty "$ttymode"
  plymouth show-splash 2>/dev/null
  ```

  也就是：先藏起 Plymouth 的启动画面，关掉终端回显，跑 `unl0kr -n`（口令打到标准输出、
  不带换行），再把终端和 Plymouth 恢复。
- **hook 做的事**：`copy_exec` 拷进 `udevadm` 和 `/usr/bin/unl0kr`（库随 `copy_exec` 进去），
  并对一张模块清单调 `manual_add_modules`。清单里有 `edt-ft5x06`、`goodix_ts`、
  `i2c_qcom_geni` 等，**没有** `st_ftm5_spi` 和 `spi_geni_qcom`。在 `MODULES=list` 下这个
  hook 不会帮我们带上触摸屏，所以触摸屏必须内建（3.2）。
- **命令行选项**（手册页）：`-m/--message`、`-C/--config-override`、`-g/--geometry=NxM@X,Y`、
  `-d/--dpi=N`、`-n`、`-v/--verbose`、`-V/--version`。
- **配置**（`unl0kr.conf(5)`，`[小节]` 下 `选项=值`）：`[general]` 的 `animations`、
  `timeout`；`[keyboard]` 的 `autohide`、`layout`、`popovers`；`[textarea]` 的 `obscured`；
  `[theme]` 的 `default`、`alternate`。合并顺序：
  `/usr/share/unl0kr/unl0kr.conf` → `/usr/share/unl0kr/unl0kr.conf.d/*` →
  `/etc/unl0kr.conf` → `/etc/unl0kr.conf.d/*` → 命令行给的覆盖文件。
- **软件包 README 里的设置步骤**：在 `/etc/crypttab` 的相关条目里加上
  `keyscript=/usr/share/initramfs-tools/scripts/unl0kr-keyscript`，然后 `update-initramfs -u`。
- **键盘布局**：布局表由 squeekboard 的布局生成。口令只能用它有的布局打出来，建议用纯 ASCII
  口令（待核实：`layout=` 能取哪些值）。

### 4.4 要改的项目文件

| 文件 | 改什么 |
| --- | --- |
| `scripts/build-rootfs.sh` 第 143–145 行 | `/etc/diting/cmdline`：`root=/dev/mapper/diting-root ro rootwait` |
| `scripts/build-rootfs.sh` 第 241–245 行 | fstab：根写 `/dev/mapper/diting-root` 或里面 ext4 的 UUID |
| `scripts/build-release.sh` 第 31–32 行 | 现在要求 `vendor_boot` 的命令行里有 `root=PARTLABEL=userdata`，否则报错退出；要接受映射设备 |
| `config/diting.conf` 第 62 行 | `DITING_ROOT_CMDLINE` 的默认值 |
| `packages/device-xiaomi-diting` | 依赖加 `cryptsetup-initramfs`、`unl0kr`；写 `/etc/crypttab`；镜像里带上 LUKS 容器（第 6 节） |
| `release/flash-diting.sh`、`release/INSTALL.md` | 安装步骤（第 6 节） |
| `docs/SAFE_TESTING.md` | 加上加密机型的恢复步骤 |

**命令行里值得一起加的**（写到 `BOOT_CMDLINE_BASE`）：

- `quiet loglevel=3`：现在 ABL 追加的 `loglevel=6` 让内核消息一直往屏幕上打，会盖住键盘。
- `vt.global_cursor_default=0`：去掉帧缓冲控制台的光标。

`console=tty0` 要留着：unl0kr 藏起来的是 Plymouth，控制台本身是它要写画面的地方；
`earlycon` 调试时有用。

### 4.5 开机那一屏

- 显示：simpledrm 在引导程序的 splash 上，解锁画面直接画在那上面。真正的显示驱动（msm）
  和面板驱动是模块，在根分区上，解锁后才加载。
- **背光**：解锁阶段没有面板驱动，亮度是引导程序留下的值。够不够亮，待核实。
- Plymouth 已在 initramfs 里。keyscript 会在问口令时把它藏起来。如果它碍事，可以在
  initramfs 里屏蔽它（待核实是否需要）。
- 触摸屏：`INPUT_EVDEV=y`，udev 在 initramfs 里，libinput 需要 udev 给设备打
  `ID_INPUT_TOUCHSCREEN` 这类属性——由 udev 的 `input_id` 内建完成，待实机确认。

## 5 LUKS 与 crypttab 参数

### 5.1 建议的格式化命令

```sh
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 256 --sector-size 4096 \
    --pbkdf argon2id --pbkdf-memory 1048576 --pbkdf-parallel 4 \
    --label diting-root \
    /dev/disk/by-partlabel/userdata
```

| 参数 | 理由 |
| --- | --- |
| `--type luks2` | 默认值；Argon2、多密钥槽、离线重新加密 |
| `aes-xts-plain64`、`--key-size 256` | 默认值；有硬件引擎的实现（3.3） |
| `--sector-size 4096` | UFS 的逻辑块是 4096，少一层扇区换算；待实测确认更快 |
| `--pbkdf argon2id` | 默认值 |
| `--pbkdf-memory 1048576`（1 GiB）、`--pbkdf-parallel 4` | 显式写死。默认是格式化时按 2 秒目标现场测出来的：在救援环境里格式化，内存和 CPU 数不同，解锁时 Argon2 的参数就不同。10 GB 内存跑 1 GiB 没问题；解锁耗时待实测 |

可选：

- `--integrity aead`（或 `hmac-sha256`）：带校验的加密，能发现密文被动过；
  `DM_INTEGRITY=y` 已内建。有性能代价，待实测。
- `--perf-no_read_workqueue --perf-no_write_workqueue`：LUKS2 把它存在头部，
  每次解锁都生效。对高速多队列设备通常更快，待实测。
- `--uuid <固定的 UUID>`：让镜像里的根映射每次一样。

### 5.2 crypttab

```
diting-root  PARTLABEL=userdata  none  luks,discard,keyscript=/usr/share/initramfs-tools/scripts/unl0kr-keyscript
```

- `PARTLABEL=userdata` 是 crypttab 支持的写法；initramfs 里 udev 会给出
  `/dev/disk/by-partlabel/userdata`。
- `discard`：UFS 支持 TRIM。开着会让“哪些块没在用”对拿不到盘的人也可见；不开，SSD/UFS
  的垃圾回收效率低一些。取舍由机主定。
- 要加性能或校验选项就接在后面：`no-read-workqueue,no-write-workqueue`
  （或格式化时就用 `--perf-*` 存进头部）。
- `tries=0` 表示不限次数重试。

### 5.3 fstab

```
/dev/mapper/diting-root  /  ext4  defaults,noatime,x-systemd.growfs  0  1
```

### 5.4 密钥槽和恢复

- 多加一把口令：`cryptsetup luksAddKey /dev/disk/by-partlabel/userdata`
- 去掉一把：`cryptsetup luksKillSlot <设备> <槽号>`
- 备份头部：`cryptsetup luksHeaderBackup <设备> --header-backup-file <文件>`；
  恢复：`cryptsetup luksHeaderRestore`。头部坏了整盘数据都读不出来，值得存一份。
- 恢复密钥：`systemd-cryptenroll --recovery-key`（需要 `systemd-cryptsetup`）。

## 6 安装方式

三条路，A 最省事，B 不经过临时口令，C 是给现有系统用的。

### A. fastboot 照旧刷，首次开机用屏幕键盘（推荐）

1. 构建主机上建一个 LUKS2 容器，口令是随机生成的**临时口令**，里面放 ext4 根文件系统
   （就是现在的 `mkfs.ext4 -d "$ROOT"` 那一步，改成先对容器做 `luksFormat`、`open`，
   再对 `/dev/mapper/...` 做 `mkfs.ext4`）。容器大小等于 `userdata` 分区（或
   `x-systemd.growfs` 能撑满的任意大小）。
2. `fastboot flash userdata rootfs.img`：LUKS 容器对 fastboot 只是一串二进制，
   `img2simg` 照常可用。`boot.img`、`vendor_boot.img` 也照常刷。
3. 首次开机：unl0kr 出现，输入临时口令 → 进系统。此时盘上没有任何用户数据。
4. 进系统后设自己的口令并去掉临时那一槽：

   ```sh
   sudo cryptsetup luksAddKey /dev/disk/by-partlabel/userdata   # 输入旧口令，再输两遍新口令
   sudo cryptsetup luksKillSlot /dev/disk/by-partlabel/userdata 0
   ```

   第 4 步之前盘上没有用户数据，临时口令被人知道也无所谓；做完这一步，临时口令就作废了。
5. 可以写一个首次开机的向导脚本（`diting-first-boot` 之类）替机主做第 4 步。

### B. 救援安装：先格式化再灌数据

1. 手机刷一个带 cryptsetup 的调试镜像（`BOOT_MODE=debug`，`diting.debug=hold`：USB NCM
   加 shell，不挂根分区）。调试镜像的 initramfs 现在不含 cryptsetup，要在它的 hook 里加。
2. 在 USB shell 里直接用自己的口令 `luksFormat`（5.1 的命令），`cryptsetup open`。
3. 把原始 ext4 镜像（`img2simg` 之前的那个）经 USB 网络灌进映射设备。那个 initramfs 里
   没有 sshd，只有 busybox 的串口 shell：手机上用 busybox 的 `nc -l -p 1234` 收（initramfs
   里有没有 `nc` 待确认），电脑上 `nc 172.16.42.1 1234 < rootfs.img`。20 GB 左右的镜像按
   USB NCM 的速度要十几分钟，速度待实测。
4. `resize2fs`（或靠 `x-systemd.growfs`）、刷 `boot.img`/`vendor_boot.img`、重启。

这条路没有临时口令，也不需要 unl0kr 的“首次开机”步骤。

### C. 现有系统原地转换

1. 把根分区完整备份出来（现在用了约 20 GB），经 USB 拉回电脑。
2. 走 B 的 1–3 步，再把备份灌回去。
3. `cryptsetup reencrypt --encrypt` 理论上也行，但它要把 223 GiB 的设备整个处理一遍，
   耗时很长，不推荐。

### D. 先不动数据，在文件上试

```sh
dd if=/dev/zero of=/var/tmp/test.luks bs=1M count=512
sudo cryptsetup luksFormat --type luks2 /var/tmp/test.luks
sudo cryptsetup open /var/tmp/test.luks test-root
sudo mkfs.ext4 /dev/mapper/test-root && sudo mount /dev/mapper/test-root /mnt
# 读写、fio、cryptsetup benchmark 都在这里做
sudo umount /mnt && sudo cryptsetup close test-root && rm /var/tmp/test.luks
```

## 7 测试计划

分四步，每一步都有回退。

| 步 | 做什么 | 不动什么 | 通过的标准 |
| --- | --- | --- | --- |
| T1 | 装 cryptsetup，在第 6 节 D 的文件容器上做 `luksFormat`/`open`/`mkfs`/`mount`/读写；`cryptsetup benchmark` | 分区、initramfs | 内核侧全部可用；记下 AES-XTS 的软件和硬件速度（`xts (qce)` 一行） |
| T2 | 只测解锁界面：做一个临时镜像，initramfs 里跑一次 unl0kr（直接调 `/usr/bin/unl0kr`，用 `-m` 给个提示） | 根分区不加密；只写 `vendor_boot_a`（先备份） | 屏幕出现键盘、触摸能输入、退出后照常开机 |
| T3 | 正式装到 `userdata`（第 6 节 A 或 B） | — | 下面的验收清单 |
| T4 | 长时间用 | — | 没有回退到非加密的理由 |

T3 的验收项：

- 解锁耗时（从键盘出现到 Phosh 登录界面）。
- `sudo cryptsetup status diting-root`、`sudo dmsetup table` 与 5.1、5.2 一致。
- `lsblk` 里 `sda37` 是 `crypto_LUKS`，下面挂着 `diting-root`；`x-systemd.growfs` 把 ext4
  撑满。
- `sudo fstrim -v /`（如果开了 `discard`）。
- 读写速度（`dd`、`fio`）对比非加密时：顺序读之前量过是 1.3 GB/s。
- 重启、关机正常；接电脑 USB 时和原来一样。
- Wi-Fi、通话、传感器、摄像头不受影响（它们都在解锁之后才启动）。
- `cryptroot` 重试：输错 3 次之后进 initramfs 的 shell，能从那里手动解锁或重启。
- initramfs 体积：`vendor_boot` 分区 96 MiB，现在镜像 20 MiB，加上 cryptsetup、unl0kr、
  libinput、libdrm、xkbcommon、字体之后的大小要量。

**回退**：`fastboot flash userdata rootfs.img`（非加密的 rootfs 镜像）会盖掉 LUKS 头，
回到现在的状态。`boot_a`/`vendor_boot_a` 写回备份即可。

## 8 安全属性与限制

- **挡得住谁**：手机丢了、关机或重启之后，拿不到口令就读不到 `userdata` 里的东西。
- **挡不住谁**：bootloader 是解锁的，也没有验证启动（ABL 的 AVB 被关掉了，Xiaomi 的签名
  也不可能给我们签）。内核、initramfs、命令行都在明文分区里，能物理接触手机的人可以把
  initramfs 换成记录口令的版本，等机主输入。这是所有主线 Linux 手机的共同限制，
  没有完整的解法。
- **USB 调试 shell**：`diting.debug=usb` 让 initramfs 在 USB 上开一个不需要登录的 root
  shell，解锁之前就有。加密机型不应该带这个参数（公开镜像本来就去掉了）。
- **口令丢失**：没有 TPM、没有厂商恢复通道，数据不可恢复。头部备份只能救“头部损坏”，
  救不了“忘记口令”。
- **内存里的密钥**：解锁后密钥在内存里，直到关机。always-online 模式不挂起，所以
  “挂起后内存密钥被读出”这类问题不存在；`luksSuspend` 是可选项。
- **LUKS 头部是明文的元数据**：能看到这是 LUKS2、用了什么 cipher、PBKDF 参数、密钥槽数量。
- **TRIM**：开了 `discard`，没在用的块对拿盘的人可见。
- **没有度量启动，也没有远程证明**。
- **口令强度**：Argon2id 抵御离线暴力破解，但口令本身仍然是最重要的一环。

## 9 性能

都没有实测，实施 T1 时填上。

| 项 | 现状 / 预期 |
| --- | --- |
| 软件 AES-XTS | `CRYPTO_XTS=y`，AES 走 `aes-lib`；ARMv8 扩展指令是否已在其后生效，待核实 |
| 硬件 AES-XTS | `xts-aes-qce` 已注册（优先级 275），但模块在解锁阶段不可用，除非内建 |
| `no-read-workqueue` / `no-write-workqueue` | 通常对高速设备有益，待实测 |
| `--sector-size 4096` | 待实测 |
| `--integrity` | 有额外开销，待实测 |
| UFS 内联加密 | dm-crypt 用不上 |
| 参照 | 非加密时顺序读 1.3 GB/s（`dd`，2 GiB） |

`cryptsetup benchmark` 会按已注册的实现逐个报数，T1 就能看出软件和硬件谁快。

## 10 待核实与风险

1. **unl0kr 能不能在 simpledrm 上画出来**：libdrm 要连接器、CRTC、dumb buffer，simpledrm
   都提供，主线手机上这么用的很多，但这台没试过。T2 验证。
2. **解锁那一屏的亮度**：没有面板驱动，亮度是引导程序留下的。太暗就要在 initramfs 里
   另想办法点亮。
3. **内核消息盖住键盘**：要加 `quiet loglevel=3`；ABL 追加的 `loglevel=6` 在命令行更后面，
   后出现的参数生效——待核实到底哪个赢。
4. **触摸屏内建后的探测时机**：稳压器、pinctrl 都是内建的，应该没问题，实测为准。
5. **libinput 认不认这个触摸屏**：取决于 udev 给设备打的属性。
6. **背光和 splash 在解锁期间会不会超时熄灭**（显示面板是命令模式，simpledrm 不发命令）。
7. **Plymouth 和 unl0kr 会不会抢画面**：keyscript 会先 `plymouth hide-splash`。
8. **initramfs 体积**是否超出 96 MiB。
9. **`x-systemd.growfs` 在 dm-crypt 设备上**正常工作。
10. **Argon2 在 initramfs 里的内存**：1 GiB 在 10 GB 的机器上没问题；8 GB 的机型要重新算。
11. **中文输入**：解锁键盘只有它自带的布局，口令建议用 ASCII。
12. **屏幕键盘布局取值**：`layout=` 支持哪些值，看安装后的 `/usr/share/unl0kr`。
13. **fscrypt + ICE** 那条路（3.4）密钥能不能写进引擎，纯属未试。
14. **`CRYPTO_USER_API`** 保持现状即可，确认 cryptsetup 在这台机器上不用 AF_ALG。

## 11 出处

- Debian cryptsetup 小组的 `README.initramfs`（Ubuntu 的包是同一份源码）：
  <https://cryptsetup-team.pages.debian.net/cryptsetup/README.initramfs.html>
- `crypttab(5)`（Debian trixie）：<https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>
- `unl0kr(1)`、`unl0kr.conf(5)`、`README.Debian`、`/usr/share/initramfs-tools/hooks/unl0kr`、
  `/usr/share/initramfs-tools/scripts/unl0kr-keyscript`：从 Ubuntu 26.04 的
  `unl0kr_3.4.2+dfsg-1_arm64.deb` 里读出来的。
- `cryptsetup-initramfs_2.8.4-1ubuntu4_all.deb` 的文件清单和
  `scripts/local-top/cryptroot`。
- 手机上的 `/etc/diting/cmdline`、`/etc/fstab`、`/etc/initramfs-tools/`、`/proc/crypto`、
  `/sys/class/block/sda/queue/crypto/`，2026-11-26 读取。
- 源码树：`arch/arm64/boot/dts/qcom/sm8450.dtsi`（`crypto@1d88000`、`crypto@1dfa000`）、
  `arch/arm64/boot/dts/qcom/sm8475-xiaomi-diting.dts`（`&spi4`）、
  `drivers/spi/Kconfig`、`drivers/input/touchscreen/Kconfig`、`drivers/md/dm-crypt.c`。
- 项目里：`scripts/build-rootfs.sh`、`scripts/build-release.sh`、`scripts/build-boot-image.sh`、
  `release/flash-diting.sh`、`release/INSTALL.md`、
  `packages/device-xiaomi-diting/initramfs-tools/`、`config/diting.conf`。
