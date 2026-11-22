# Camera patch collection (Xiaomi 12T Pro / Redmi K50 Ultra "diting", CN)

本目录（`diting-ubuntu/kernel/`）是内核补丁的正式位置，与构建服务器
`mt8788-build:~/k50ultra/diting-ubuntu/kernel/` 完全同步（rsync，含全部 102
个补丁；2026-11-22 清单哈希已核对一致）。自动化流程：`make kernel` 由
`scripts/prepare-kernel.sh` 按 `patches/*.patch` 文件名顺序 `patch -p1` 应用。
本文件只是摄像头相关补丁的索引，`PATCHES-CAMERA.md` 与 `camera-ipa/` 不参与
自动化（prepare-kernel 只认 `patches/*.patch`）。

本地改动 → 构建服务器 → 出包：

```sh
# 本地编辑 kernel/patches/ 或 kernel/config/ 后同步过去并编译（tmux 内）
rsync -a --delete diting-ubuntu/kernel/patches/ mt8788-build:'~/k50ultra/diting-ubuntu/kernel/patches/'
rsync -a --delete diting-ubuntu/kernel/config/  mt8788-build:'~/k50ultra/diting-ubuntu/kernel/config/'
ssh mt8788-build "tmux new-session -d -s k50ultra-build 'cd ~/k50ultra/diting-ubuntu/ubuntu-diting && make kernel 2>&1 | tee output/logs/kernel.log'"
```

当前状态（2026-11-22 实测）：**主摄 S5KHM6 与超广角 S5K4H7 均可出图拍照**（Snapshot 实拍验证）。**主摄执行器 DW9800V 已驱动（0103/0104），focus_absolute 0..1023 实测写入成功、镜头移动正常**。前摄 IMX596、微距 GC02M1 仍无驱动。录像仍走软 ISP + 软编码（无硬编码器，性能受限）。

## 目录

- `patches/` — 全部 102 个内核补丁（按应用顺序编号，`patch -p1` 格式）；下表只索引摄像头相关的 25 个
- `config/diting.config` — 内核 config 片段（含 `CONFIG_VIDEO_S5KHM6=m`，随 r53 新增）
- `camera-ipa/` — libcamera simple（软 ISP）调参文件；`s5khm6.yaml` 是 r53 随手从 s5khp1.yaml 改名而来，装在手机 `/usr/share/libcamera/ipa/simple/`（后续应并入 device-xiaomi-diting 包）

## 补丁索引

### 基础设施（时钟 / ISP / C-PHY）

| # | 补丁 | 内容 |
|---|---|---|
| 0055 | clk: camcc-sm8450 park RCGs on XO | 摄像头时钟控制器修复（disable 时停靠） |
| 0056 | clk: camcc-sm8450 RETAIN_FF_ENABLE | 摄像头时钟控制器保持使能 |
| 0057 | media: qcom-camss SM8450 support | CAMSS ISP 驱动支持 SM8450/8475（三星 Tab S8 摄像头栈移植） |
| 0058 | dts: Enable CAMSS | diting DT 启用 CAMSS |
| 0070 | media: camss add C-PHY support | CAMSS 增加 C-PHY 接收支持 |
| 0071 | media: camss correct C-PHY config | C-PHY 配置修正 |
| 0072 | media: camss C-PHY per-trio rates | C-PHY 速率设置按 trio 计（vendor 阈值口径） |
| 0073 | media: camss C-PHY CSIPHY v2.1 (SM8450/8475) | CSIPHY v2.1 的 C-PHY 速率档寄存器（1.7/2.1/2.5 Gsym/s） |

### 供电（WL2866D 相机 LDO）

| # | 补丁 | 内容 |
|---|---|---|
| 0062 | dt-bindings: Willsemi WL2866D | WL2866D 绑定 |
| 0063 | regulator: WL2866D driver | WL2866D 相机 LDO 驱动（AVDD1/AVDD2） |
| 0064 | dts: Add the camera LDO | diting DT 启用 WL2866D（i2c5） |

### 超广角 S5K4H7（已可工作）

| # | 补丁 | 内容 |
|---|---|---|
| 0059 | dt-bindings: S5K4H7 | 传感器绑定 |
| 0060 | media: i2c: S5K4H7 driver | 传感器驱动（camregs 固件加载寄存器表） |
| 0061 | dts: Add the rear ultrawide | DT 节点 + CSIPHY1 链路 |
| 0066 | dts: Fix the ultrawide | 超广角修正 |

### 主摄（EEA 机型为 S5KHP1；CN 机型为 S5KHM6）

| # | 补丁 | 内容 |
|---|---|---|
| 0067 | dt-bindings: S5KHP1 | 传感器绑定 |
| 0068 | media: i2c: S5KHP1 driver | 驱动（camregs；s5khm6 驱动的直接模板） |
| 0069 | dts: Add the rear main camera | DT 节点（CCI0 i2c1 0x10、MCLK2、四路供电、复位） |
| 0074 | dts: Link the main camera | 接到 CSIPHY2（C-PHY 3 trio） |
| 0075 | media: ak7375 AK7314 | AK7314 执行器支持（EEA 模组用） |
| 0076 | dts: lens + EEPROM | AK7314 执行器节点 + 模组 EEPROM(0x51) |
| 0099 | dts: Disable S5KHP1 | CN 机型装的是 HM6：先禁用 HP1 节点（r52） |
| **0100** | **dt-bindings: S5KHM6** | **HM6 绑定（本目录新增，r53）** |
| **0101** | **media: i2c: S5KHM6 driver** | **HM6 驱动：chip id 0x1ad6、单 PLL 单链路频率 1195.83 MHz、像素钟 1639.995 MHz、6 模式（12000x9000@8 … 720p@360），camregs 寄存器表** |
| **0102** | **dts: Use the S5KHM6 (CN)** | **camera@10 切到 samsung,s5khm6：firmware-name s5khm6-wide.camregs、link-frequencies <1195830000>、移除 AK7314 执行器（CN 模组是 DW9800V）** |
| **0103** | **media: dw9807-vcm: Add DW9800V** | **DW9800V 变体：跳过状态轮询、WL2866D 供电管理、vendor 初始化序列（控制寄存器复位→SAC2、0x06=0x80、0x07=0x62，源自 Motorola DW9800V 驱动 + CN 模块数据）** |
| **0104** | **dts: Add the DW9800V lens actuator** | **actuator@c 节点（dongwoon,dw9800v）+ camera@10 的 lens-focus 引用 → libcamera 驱动真实自动对焦** |

0100-0102 关键数据来源：CN 模块 bin（`com.qti.sensormodule.diting_sunny_s5khm6_wide.bin`：chip id、供电时序、模式表、DW9800V 执行器）+ Motorola `mot_vicky_s5khm6` MTK 驱动（像素钟 1639.995 MHz 交叉验证，其 PLL 倍率比恰为 MCLK 24/19.2 之比）。

## 固件（不在本目录，手机上由 firmware 包生成）

- `/usr/lib/firmware/qcom/sm8475/xiaomi/diting/s5khm6-wide.camregs` — `chromatix-to-camregs.py` 从 CN 模块 bin 转换（init + mode0..7，驱动用其中 6 个）
- `s5k4h7-ultra.camregs` — 超广角同法生成

## 未做 / 待办

- DW9800V 执行器驱动（对焦）— CN 模组数据在模块 bin actuatorDriver 节点（0x0c）
- 前摄 IMX596、微距 GC02M1 驱动（模块 bin 均在 CN ROM 里：`..._sunny_imx596_front.bin`、`..._ofilm_gc02m1_macro.bin`）
- libcamera sensor properties / soft IPA 对 s5khm6 的正式调参（当前为 s5khp1.yaml 改名占位；`cam` 有 "No static properties / sensor helper" 告警）
- s5k4h7.yaml 未装进手机（simple IPA 回落到 uncalibrated.yaml）
