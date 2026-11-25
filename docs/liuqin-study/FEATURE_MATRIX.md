# 功能逐项核验：liuqin 的硬件支持表 vs diting

> liuqin 一侧来自其 README（v0.8.0）与 git 历史；diting 一侧除注明“文档”外都是 2026-11-26 在
> 手机上实测（`7.2.10-diting #52`，Ubuntu 26.04.1）。原始输出在
> `/Users/f/work/redmi-k50ultra/liuqin-study/raw/probe{1,2,3}.txt`。
> 图例：✅ 可用 · 🟡 部分 · ❌ 不可用 · ➖ 该机没有这个硬件 · ❓ 未验证

## 1. 总表

| # | 功能 | 对方实现（状态） | diting 的硬件 | 我们的状态 | 差距 / 说明 |
| --- | --- | --- | --- | --- | --- |
| 1 | SoC / CPU | SM8475（✅） | SM8475 | ✅ | 我们多了 modem；CPU 容量 r54 已补（对方 `1cd8848c870a`） |
| 2 | GPU / 桌面合成 | Adreno 730 / Freedreno / Turnip / 发行版 Mesa（✅） | A730v3 | ✅ 实测 | 相同的 Mesa 栈；我们有 GMU 超时导致黑屏的已知问题，对方有一批 a6xx 修复（见 §3） |
| 3 | 内置存储 | UFS / ext4（✅） | UFS + ext4（userdata 220 GB） | ✅ 文档 | 对方旧提交 `68051cc5e986` 加 UFS unipro 850 MHz，我们没有；我们的状态文档写着“runs at 300 MHz table”，值得试 |
| 4 | 内置显示 | NT36532 双 DSI + DSC，2880×1800 120 Hz（✅） | 单 DSI DSC 命令面板 1220×2712，60/90/120 Hz | ✅ 实测 | `card1-DSI-1 connected 1220x2712` |
| 5 | 手动亮度 | KTZ8866（✅） | DSI 背光 | ✅ 实测 | `/sys/class/backlight/ae94000.dsi.0`，max 2047；HBM / AOD 未做 |
| 6 | 触控 | NT36532 / SPI（✅） | ST FTM5 / GENI SPI | ✅ 实测 | `event3 "STM FTM5 Touchscreen"` |
| 7 | 磁吸键盘 | Nanosic WN8030（✅） | ➖ 手机 | ➖ | 不适用 |
| 8 | 指纹 | FPC1264 / libfprint TOD / fprintd（✅） | **Goodix 光学屏下** | ❌ 未开始 | 芯片厂商不同，对方方案不能直接移植；详见 FINGERPRINT.md |
| 9 | 保护套开合 | GPIO / SW_LID（✅） | ➖ 手机 | ➖ | 不适用 |
| 10 | Wi-Fi | QCA6490 / ath11k（✅） | WCN6855 hw2.1 | ✅ 实测 | 已关联 5805 MHz / 80 MHz，-54 dBm，RX 1080 Mbit/s |
| 11 | 蓝牙 | QCA6490 / hci_qca / BlueZ（✅） | 同 | ✅ 实测 | 控制器已上电，有已配对设备 |
| 12 | USB 设备模式 | DWC3 / NCM，开发者模式默认关闭（✅） | DWC3 + eUSB2 | ✅ 实测 | 本次 SSH 即走 `usb0` NCM，high-speed |
| 13 | USB OTG / 主机模式 | USB-C 数据角色切换 / UCSI（✅） | 同 SoC，eUSB2 | ✅（仅 USB 2.0） | r51（0098）起支持；实测 `data_role` 为 `host [device]`，有角色切换节点。**对方的 USB3 SuperSpeed 对我们不适用**：原厂 DT 就是 `high-speed`，我们的 OTG.md 记录主板没接 SS 走线 |
| 14 | USB-C 外接显示 | DP Alt Mode / FSA4480（✅） | 未知 | ❌ / ❓ | 原厂 DT 没有 mux / altmode 节点，QMP USB3/DP PHY 节点存在但 `disabled`；K50 Ultra 官方规格无视频输出 |
| 15 | 扬声器 | 4 × CS35L41 / AudioReach（✅） | 2 × CS35L41 | ✅ 文档 | 硬件数量不同；我们带保护固件和出厂校准（T22/T23） |
| 16 | 内置麦克风 | WCD938x / SoundWire，单声道（✅） | WCD938x，两个模拟麦克风 | ✅ 文档 | 我们多一路（T16） |
| 17 | H.264 硬解 | Iris2 / V4L2（✅） | iris | ✅ 实测 | 我们另有 HEVC（含 10-bit）和 VP9；对方没有浏览器硬解。详见 VIDEO_DECODE.md |
| 18 | 后置摄像头 | S5KJN1 / CAMSS / 软件 ISP（🟡 无自动对焦） | 超广角 S5K4H7 + 主摄 S5KHM6 | ✅ / 🟡 | 软件ISP；有自动对焦和调谐文件（T28–T34、r53）。实测 libcamera 0.7.0 列出两个摄像头 |
| 19 | 加速度计 / 自动旋转 | SLPI / SSC / iio-sensor-proxy（✅） | SLPI（lsm6dso 等） | ✅ 文档 | 我们另有陀螺仪、磁力计、环境光、距离传感器（T26） |
| 20 | 电源键 / 音量键 | PMIC / GPIO（✅） | 同 | ✅ 实测 | `pmic_pwrkey`、`pmic_resin`、`gpio-keys` |
| 21 | 电池状态 / 充电 | qcom_battmgr / UPower + 状态栏功率（✅） | 同固件系列（M81） | 🟡 | **电量单位是错的**（见 §3.1）；没有充电功率显示、没有限充 |
| 22 | 快充 | MiPPS / USB PD PPS（✅） | 小米 120 W | ❌ | 对方有一整套内核接口加认证守护进程；原厂模块同为 `qti_battery_charger_main_m81.ko`。详见 KERNEL_COMMITS.md |
| 23 | 电脑 USB 供电 500 mA | 🟡 | 同 | 🟡 | 我们上报 `input_current_limit 1600000`、`usb_type Unknown`；对方 `e5dcff1232de` |
| 24 | 关机充电 | 启动阶段充电模式（🟡） | 同 PMIC | ❌ | 对方有内核加用户态的一套（`device/charger-mode/`） |
| 25 | 待机 | s2idle（🟡 未优化） | 同 | 🟡 | 我们 s2idle 和 deep（PSCI）都能进出（T12/T15）；共同的问题是 SoC 级电源域不塌缩 |

对方写“暂不支持”而我们已经有的：RTC（补丁 0028）、陀螺仪 / 磁力计 / 环境光、其他格式硬解、
浏览器硬解、deep suspend、蜂窝网络与通话。两边都没有的：硬件视频编码、前置摄像头、休眠到磁盘
（我们有 `disk` 状态但没测过）。对方有而我们没有的：指纹、快充认证、关机充电、DP 输出、USB3、
GNOME 桌面与安装器 / 双系统切换。

## 2. 实测明细（diting）

以下都是 2026-11-26 从 USB 网络 SSH 读取的只读信息。

### 2.1 系统

```
Linux diting 7.2.10-diting #52 SMP PREEMPT 2026-10-11 aarch64 GNU/Linux
model = "Xiaomi 12T Pro / Redmi K50 Ultra"   compatible = xiaomi,diting qcom,sm8475
Ubuntu 26.04.1 LTS
systemctl is-system-running = running（没有失败的单元）
remoteproc: slpi / adsp / cdsp / modem 都是 running，固件 qcom/sm8475/xiaomi/diting/*.mbn
```

### 2.2 GPU

```
eglinfo -B -p surfaceless:  EGL 1.5 Mesa，OpenGL ES 3.2 Mesa 26.0.8-1ubuntu0.3
                            vendor: freedreno   renderer: FD730   GLSL ES 3.20
vulkaninfo --summary:        Turnip Adreno (TM) 730，IntegratedGpu，Vulkan 1.4.335，
                            turnip Mesa driver 26.0.8-1ubuntu0.3（另有 lavapipe 软件设备）
vkcube --wsi wayland（以 _greetd 身份在锁屏合成器上跑 5 s）: "Selected GPU 0: Turnip Adreno (TM) 730"
包: libgl1-mesa-dri 26.0.8-1ubuntu0.3，mesa-vulkan-drivers 26.0.8-1ubuntu0.3（Ubuntu 仓库原版，没有补丁）
devfreq 3d00000.gpu: simple_ondemand，空闲 220 MHz
dmesg: "Loaded GMU firmware v4.0.7"；adreno 3d00000.gpu（vdd / vddcx 用的是 dummy regulator）
合成器: phoc（Phosh 0.54.0-1diting1）
```

所以“GPU / 桌面合成用发行版 Mesa 做 GLES 和 Vulkan 硬件加速”这一条，我们的设备同样成立。

已知问题（KNOWN_ISSUES）：GMU HFI 消息会间歇超时，从空闲恢复时出过 GPU fault，恢复后 GMU
不再初始化，屏幕停在黑屏。对方树里与 a6xx / GMU 相关的提交见 KERNEL_COMMITS.md。

### 2.3 显示、亮度、输入

```
/sys/class/drm/card1-DSI-1  connected 1220x2712（另有 card1-Writeback-1）
/sys/class/backlight/ae94000.dsi.0  brightness=80 max_brightness=2047
input: event0 pmic_pwrkey · event1 pmic_resin · event2 gpio-keys
       event3 "STM FTM5 Touchscreen" · event4 "XIAOMI-DITING Headset Jack"
```

### 2.4 无线

```
iw dev wlp1s0 link:  SSID fc_5G  freq 5805.0  signal -54 dBm
                     rx bitrate 1080.6 MBit/s 80MHz HE-MCS 10 HE-NSS 2
bluetoothctl show:   Controller 96:D3:31:49:57:72 (public)  Powered: yes  Manufacturer 0x001d
                     已配对设备: HHKB-Hybrid_4
```

### 2.5 USB / Type-C

```
/sys/class/udc/a600000.usb:  maximum-speed high-speed  current_speed high-speed  state configured
/sys/class/typec/port0:      data_role "host [device]"   power_role "source [sink]"
                             usb_capability "usb2 [usb3]"   （数值的含义未核对内核源码）
port0-partner: pd0 revision 3.0，number_of_alternate_modes 0
设备树: usb@a600000  maximum-speed="high-speed"  dr_mode="otg"  phy-names="usb2-phy"  usb-role-switch
        phy@88e8000   compatible="qcom,sm8450-qmp-usb3-dp-phy"  status="disabled"
        pmic-glink 下有 usb-c-connector 节点（power-role / data-role 都是 dual），
          ports 里只接了高速（USB2）那一路 → usb_1_dwc3_hs，没有 SuperSpeed 那一路
        pmic-glink 的 compatible 是 "qcom,sm8450-pmic-glink", "qcom,pmic-glink"（没有 sm8475）
port0 的 usb_capability 读作 "usb2 [usb3]"（这个属性的打印规则我没有核对清楚）
```

原厂 DT（`vendor_boot_b` 的 DTB 加 `dtbo_b` 第 2 项 "Diting" 覆盖层）里 `usb@a600000` 是
`dr_mode="peripheral"`、`maximum-speed="high-speed"`，覆盖层只加了 `usb-role-switch`。我们的 `ubuntu-diting/docs/OTG.md` 写明“主板没有把 SuperSpeed 走线接到连接器”。因此：

- 对方的 OTG 主机模式我们已经有了（USB 2.0）。
- 对方的 USB3 SuperSpeed（`ccee5e821158` + `10bddb4202c8`）和 DP Alt Mode（`8d5005650cfd` 等）
  在 diting 上大概率没有硬件基础。固件经 UCSI 报告的端口能力里出现了 `usb3` 字样，这是唯一
  反证，要下结论得实测。如果确认要上，这两个 PHY 补丁就是起点。

### 2.6 电池与充电（现状）

```
qcom-battmgr-bat:  capacity 98   voltage_now 4419000 µV   current_now 293000 µA   status Charging
                   charge_counter 3932        ← 应为 µAh，数值看起来是 mAh
                   power_now 10000000         ← 10 W，与 4.42 V × 0.29 A ≈ 1.3 W 不符
                   charge_full / charge_full_design: No data available
                   cycle_count 1390   state_of_health 79   model_name L12_5000mah   temp 29.2 °C
qcom-battmgr-usb:  online 1   voltage_now 5161000   current_now 603000   current_max 1600000
                   input_current_limit 1600000   usb_type "Unknown"
ucsi-source-psy:   usb_type PD_PPS   current_now 1500000
```

对方针对同一固件系列有一组修复，见 §3.1 和 KERNEL_COMMITS.md。

### 2.7 温控

37 个 thermal zone 带触发点（CPU 90 / 95 / 110 °C，GPU 85 / 90 / 110 °C，AOSS 115 / 125 °C），
5 个 cooling device：`cpufreq-cpu0`、`cpufreq-cpu4`、`cpufreq-cpu7`、`devfreq-3d00000.gpu`、
`ath11k_thermal`。zone 与 cooling device 的绑定（`cooling-maps`）没有核对。BRINGUP_STATUS 里
“Thermal: NOT STARTED”那一行已经过时。

### 2.8 其它

```
/sys/power/mem_sleep: s2idle [deep]      /sys/power/state: freeze mem disk
diting-sensors.service: active（hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp）
iio-sensor-proxy.service: enabled (static)
摄像头: media0 = Qualcomm Camera Subsystem（6 个 CSIPHY、5 个 CSID）
        libcamera 0.7.0 simple pipeline: cci@ac15000/i2c-bus@1/camera@10（s5khm6，调谐 s5khm6.yaml）
                                        cci@ac15000/i2c-bus@0/camera@2d（s5k4h7）
声音: wpctl 列出 alsa_output.platform-sound.playback.0.0
TEE:  /dev/tee0（模块 qcomtee）；dmesg: "qseecom: found qseecom with version 0x1402000"
                                  "qseecom: untested machine, skipping"
```

## 3. 需要展开的几项

### 3.1 电量单位

`charge_counter = 3932`：满容量 5000 mAh、健康度 79 %、电量 98 % → 约 3900，所以这个数是 mAh，
而 ABI 要求 µAh，差 1000 倍。`power_now = 10000000` 是 10 W，也不对。对方提交
`787d0f7bf966`“fix(power): correct SM8475 battery telemetry units”正是改这个：给计数乘 1000
（带溢出检查），并把 `POWER_NOW` 和两个时间估计从属性列表里去掉（“Xiaomi's POWER_NOW is a
fixed placeholder”）。我们读到的 `power_now = 10000000`、`time_to_full_avg = 60` 就是这类占位
值（推断）。我们自己的三个 battmgr 补丁（0025、0091、0093）都没有碰这两个量。

它不能直接套：对方整组都依赖 `qcom,sm8475-pmic-glink` 这个 compatible 选出的 SM8475 变体，
我们的设备树没带（见 §2.5）。逐个提交的分析和移植时要改的地方在 KERNEL_COMMITS §5.5。

### 3.2 快充

我们的 BRINGUP_STATUS 写着“no charge-limit control”“charging under load/temperature 未测”，
也没有任何小米充电器认证。对方用同一代 ADSP 充电固件做到了 MiPPS 认证 + 标准 PPS 放行，
并在 GNOME 状态栏显示充电功率。diting 的原厂模块也叫 `qti_battery_charger_main_m81.ko`，系列
相同（M81），但不是同一个二进制：对方从小米 67 W 充电器和双电量计推出来的属性编号与流程，
在 120 W、单电量计的 diting 上要重新确认。驱动逻辑本身几乎是通用的。

### 3.3 GPU 相关的对方提交

对方的 a6xx 提交里一部分是上游已合并、我们也已有的（`ceba4ccedbe4` GMU 固件初始化超时、
`1fccb137b380` 挂起后残留 rpmh 投票、`058c7fab4e1f` retire 前先恢复硬件、`1ffc4b5ff464`
a7x 家族的 `gx_is_on`）。另一部分我们没有，其中三个与我们的症状直接对应：`b9e43fbe6b23`
启动 GMU 前屏蔽 HFI 中断、`cb8be68ec106` HFI 中断只清 CM3 fault 位（这两个上游已合并、
晚于 7.2.10，提交说明与我们“OOB GPU_SET 超时、CP fault at iova 0、恢复后卡死”的现象逐条
吻合）、`355dd22d6a31` 挂死恢复时强制冷启动（针对“恢复后 GMU 不再初始化”）。其余：
`018982b5e1ac` A6xx 恢复失败后停止重放并让 fence 报错、`fdf3c8b8b912` GPU 终止故障后
legacy GEM close 能退出、`03b536ad4e2c`（Sam Day）`msm_gem_submits` 的 vmalloc 回退、
`0301490788d9` 暴露 `gpu_busy_percent`、`d54edba9153c` 给 liuqin 的 OPP 发送依赖 GPU 的
CX corner、`40d6ee58b96e` 带上 Cape 的显示 / 串口 / GPU 工作电压投票、`8ec7416f90f6` 恢复
扫描前先恢复 DPU 核心时钟 OPP 投票。逐个补丁的分析见 KERNEL_COMMITS.md §5.1。

### 3.4 传感器

对方把 SLPI 的启动交给用户态（`569f79be4a7d` 加模块参数 `qcom_q6v5_pas.slpi_auto_boot`，
启动参数里 `slpi_auto_boot=0`），并自带一套传感器栈构建脚本和补丁
（`tools/build-liuqin-sensors-stack.sh`、`device/sensors/`）。我们已经有能用的栈
（hexagonrpcd-diting、libssc-diting、iio-sensor-proxy 3.9-0diting1），这一项没有需要借的。
