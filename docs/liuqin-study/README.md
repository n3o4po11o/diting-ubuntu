# liuqin（小米平板 6 Pro）移植项目对比研究

> 目的：同一颗 SoC（SM8475）的 liuqin 主线移植项目在 Linux 6.17 下做成了 H.264 硬解、指纹、
> 快充等功能。这里把它的每一项功能拿到 diting 上核验，审计它的内核提交，分析它的 rootfs，
> 找出可以拿过来的东西。
>
> 完成于 2026-11-26。各文档里标“评估”“推断”的是判断，其余都注明了证据来源。

## 结论

### 1. 视频硬解：我们更强

我们的系统能解 H.264，还支持 HEVC（含 10-bit Main10）和 VP9。实测 8-bit 三种格式和 10-bit
HEVC 都与软解逐帧逐字节一致（1080p 和 4K），4K HEVC 10-bit 硬解约 125 fps、CPU 开销只有软解
的 1/25。对方只有 H.264，没有浏览器硬解，内核侧是一套独立的 SM8450 iris 平台数据，没有值得
换过去的东西。

实测顺带确认了我们自己的两个问题（之前文档写的是“未测试”）：

- **VA-API 路径解 10-bit 是坏画面**（`libva-v4l2-stateful` 把 P010 当 NV12 读，已截图）。
- **GStreamer 的 `v4l2vp9dec` 解 VP9 会插入坏帧并丢帧**；浏览器走的 VA-API 不受影响。

详见 [VIDEO_DECODE.md](VIDEO_DECODE.md)。

### 2. 25 项功能逐项对照

对方的 GPU 一行——“Adreno 730 / Freedreno / Turnip / 发行版 Mesa，桌面合成与应用的 GLES、
Vulkan 硬件加速”——**我们的设备同样成立**：实测 `freedreno / FD730 / OpenGL ES 3.2 Mesa
26.0.8`、`Turnip Adreno (TM) 730 / Vulkan 1.4`，都是 Ubuntu 仓库的原版 Mesa，`vkcube` 在锁屏
合成器上正常渲染。

我们的显示、触控、Wi-Fi、蓝牙、USB 设备 / 主机模式、扬声器、麦克风、摄像头、传感器、通话
都可用，多数比对方完整（我们有 modem、陀螺仪 / 磁力计 / 环境光、deep suspend、RTC）。对方
独有的是**指纹、快充认证、关机充电、DP 输出 / USB3、GNOME 桌面**。详见 [FEATURE_MATRIX.md](FEATURE_MATRIX.md)。

### 3. 指纹：不能直接移植，但路是通的

diting 用的是 **Goodix 光学屏下指纹**（原厂 `dtbo`：`fingerprint_goodix { compatible =
"goodix,fingerprint"; … }`），对方是 **FPC1264**。对方整套方案里传感器驱动、TA、命令协议都是
FPC 专属的。已经查清的：

- 原厂驱动 `goodix_fod.ko` 的 ABI：字符设备 + `GF_IOC_*` ioctl + **netlink 中断通知**，不碰
  SPI（总线归安全世界）。
- diting 的两个指纹 TA `fingerpr` 和 `gfdit` 在 `modem_a` 的 `/image/` 里，**是未加密的
  ARM64 代码**，可以逆向。
- 上游 7.2.10 的 QSEECOM 只有内核内的两个符号，**没有用户态的 TA 加载和 listener**，要指纹就
  得移植一套 QSEECOM TEE 驱动。
- 更直接的参考是同一个驱动作者的 Goodix 项目
  [`wrobelda/goodix-fp-spi-linux`](https://github.com/wrobelda/goodix-fp-spi-linux)（据称基于
  v7.1）；未知的是 diting 这一代 TA 的协议。

详见 [FINGERPRINT.md](FINGERPRINT.md)。

### 4. 内核提交审计

对方自 6.17-rc1 以来 348 个非合并提交。零模糊度的补丁检查：100 个我们已有，30 个我们没有且能
直接套用，218 个冲突。再用 GitHub compare 对 33 个“从上游摘樱桃”的提交做了确定性判定：20 个
已在 v7.2.10 里，13 个不在。真正值得拿的按“小、低风险、正对我们的已知问题”排序：

1. **GMU / 黑屏**：`b9e43fbe6b23`（启动 GMU 前屏蔽 HFI 中断）、`cb8be68ec106`（HFI 中断只清
   CM3 fault 位）——上游已合并但晚于 7.2.10，共 10 行，提交说明逐条描述了我们的症状；加
   `355dd22d6a31`（挂死恢复时强制冷启动）。
2. **显示时钟**：`960054da68da` + `a32e4e25f6c0`，上游已合并，对应我们开机的
   `rcg didn't update its configuration` 警告，并点名 SM8475 的花屏。
3. **挂起与 DSP 链路**：`594134933699`（GENI 串口挂起时屏蔽中断，蓝牙走这个驱动）、
   `5bbdbea6a307`（glink 不再丢端点就绪前的消息，对应我们 T46 的服务晚到）。
4. **电量单位**：`787d0f7bf966` 正是修我们 `charge_counter` 是 mAh、`power_now` 是占位值的那个
   提交，但它依赖对方的 SM8475 变体，要手工移植。
5. **充电整组**（约 1500 行）：SM8475 变体、XM 传输、小米认证接口、电脑口 500 mA、QC 报 DCP。
   diting 的原厂模块与对方同名同系列（M81），但属性编号得从 diting 自己的模块重新推。

详见 [KERNEL_COMMITS.md](KERNEL_COMMITS.md)。

### 5. rootfs：拿方法，不拿 tarball

对方的 rootfs 不是 debootstrap 出来的，而是把 Canonical 的 `ubuntu-26.04-desktop-arm64.iso` 里
的 GNOME 50 桌面 squashfs 原样解出来，再在 QEMU chroot 里装 Firefox deb、7 个 apt 包和几个
`liuqin-*` deb。整条启动链（BusyBox initramfs、分区名、安装器、槽位轮换）都是 liuqin 专属的，
不能直接拿来启动。值得借鉴的是：ISO 基底 + deb 集合的做法、一批与硬件无关的 GNOME 调优
（电源键策略、时钟下限、合成器就绪后再起音频、屏幕键盘防崩等），以及它的构建和测试工程。
建议在我们的构建系统里加一个 GNOME 口味来用这套做法。详见 [ROOTFS.md](ROOTFS.md)。

## 文件索引

| 文件 | 内容 |
| --- | --- |
| [FEATURE_MATRIX.md](FEATURE_MATRIX.md) | 对方硬件支持表 25 项逐项对照 diting，附实测明细 |
| [VIDEO_DECODE.md](VIDEO_DECODE.md) | H.264 / HEVC / VP9 / AV1 能力矩阵、正确性、性能、发现的问题 |
| [FINGERPRINT.md](FINGERPRINT.md) | diting 指纹硬件与 TA 的鉴定，QSEECOM 现状，对方栈分析，实验顺序 |
| [KERNEL_COMMITS.md](KERNEL_COMMITS.md) | 348 个提交的审计、逐主题精读与关键代码、采纳顺序；§8 是采纳记录（第一批补丁 0106–0114 的状态） |
| [ROOTFS.md](ROOTFS.md) | 对方 rootfs 的构建管线、启动模型、deb 包、应用清单、diting 的三种用法 |

## 对方项目概况

| | |
| --- | --- |
| rootfs / 设备仓库 | `https://github.com/yzddmr6/xiaomipad-6pro-mainline`，main `24d5ccd`，v0.8.0（2026-11-16），原创代码 MIT |
| 内核仓库 | `https://github.com/yzddmr6/linux-sm8450-liuqin.git`，分支 `liuqin-6.17`，HEAD `ed0dad5d20d0`；基于 sm8450-mainline/linux（6.17-rc1） |
| 桌面 | Ubuntu 26.04 + GNOME 50，可与 Android 双系统（KernelSU 模块 + 槽 A 轮换） |
| 文档 | `README.md`（中文默认）、`docs/{CAMERA,FASTCHARGE,FLASHING,INSTALL-TESTING,BUILD,WAYDROID,FINGERPRINT,CI}.md` |
| 在构建服务器上的位置 | `~/k50ultra/based-liuqin/{linux-sm8450-liuqin,xiaomipad-6pro-mainline}` |

## 方法与证据

- **手机实测**：2026-11-26 经 USB 网络 SSH（`ubuntu@172.16.42.1`）做的只读探测，手机当时运行
  `7.2.10-diting #52`，Ubuntu 26.04.1。没有改手机上的任何配置：测试文件都放在 `/tmp` 并已删除，
  原厂分区只做过只读挂载并已卸载，在锁屏合成器上跑过 5 秒 `vkcube`。
- **原厂数据**：从手机的 `vendor_boot_b`、`dtbo_b`、`modem_a` 分区只读拷出，解析结果在
  `/Users/f/work/redmi-k50ultra/liuqin-study/raw/stock/`。
- **内核审计**：`liuqin-study/scripts/check-upstreamed{,-strict}.sh`（补丁法）、
  `check-upstream-git.sh`（因上游仓库是浅克隆而作废）、GitHub compare API
  （`raw/cherry-check.txt`），再到 7.2.10 源码里逐项 grep。补丁副本 `raw/patches/`（348 个）。
- **对方仓库文本**：`/Users/f/work/redmi-k50ultra/liuqin-study/raw/mainline/`（不含固件二进制）。
- 所有脚本和原始输出都在工作区的 `/Users/f/work/redmi-k50ultra/liuqin-study/`（`scripts/`、
  `raw/`），不在仓库内。
- 四个子任务分别精读了充电 / 电池补丁、其它内核补丁、rootfs 构建链、指纹栈；它们报告里的
  关键结论我都到源码或手机上核对过，核对中发现的不一致已在各文档里更正。
- 连接卫生按 AGENTS.md：远程命令合并执行，长任务放 tmux。构建服务器上另有一个 `k50ultra-flash`
  会话在跑，所以没有动远程构建工作区。

## 还没做的

- 第一批补丁（0106–0115）已写好并在内核容器里编译通过，其中电量单位的两个在手机上
  用热加载验证过；0115 已提交（手机上一直在跑的设备树）。0106–0114 要换内核镜像才能
  测，还没有刷到手机上，也还没有提交。
  状态和验收项见 [KERNEL_COMMITS.md §8](KERNEL_COMMITS.md)。
- diting 是否真的没有 SuperSpeed 走线：只有 OTG.md 的结论和原厂 DT 的 `high-speed`，固件经
  UCSI 报告的端口能力是 `usb2 [usb3]`，没有实测。
- VP9 的 GStreamer 坏帧、VA-API 10-bit 坏画面只确认了现象，没有查根因。
- 指纹只做到静态侦察。diting 的 TA 协议、`keymaster64` 的命令号、原厂 HAL 的调用都还没看。
- 充电整组的 XM 属性编号要从 diting 的原厂模块 `qti_battery_charger_main_m81.ko` 重新推导。
- 第一轮测试里出现过一次 32 秒的解码停顿，没有复现。

## 测量中踩过的坑（留作以后参考）

- 用 `bash -s` 通过 SSH 喂脚本时，命令一读 stdin 就会把脚本剩下的部分吃掉。改成先
  `cat > /tmp/x.sh` 再 `bash /tmp/x.sh </dev/null`。
- 把 ffmpeg 的 stderr 并进管道算 md5，会得到“每次都不一样”的假象（报错文本里带地址）。
- V4L2 解码缓冲区按编码高度分配，1080p 的亮度平面占 1088 行，但色度平面在 1920×1080 处。
  GStreamer 直接 `filesink` 出来的就是这种带填充的原始缓冲区。
- 补丁法的模糊度会产生“我们没有”的假阳性。`1ffc4b5ff464`（a7x 的 `gx_is_on`）和
  `b8f84456a316`（dwc3 角色的用户态控制）实际 7.2.10 里都有，只是函数被重构过。
- 本地 `device-data/images/vendor_boot_a.img` 是我们自己构建的镜像，不是原厂的。
- 构建服务器上的 `~/k50ultra/diting-ubuntu/kernel/upstream` 是浅克隆，不能做祖先判断。
