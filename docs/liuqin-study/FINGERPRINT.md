# 指纹：diting 的硬件鉴定，与 liuqin 方案的可移植性

> 2026-11-26。证据来源：手机 `vendor_boot_b` / `dtbo_b` / `modem_a` 分区的只读拷贝（我自己取的，
> 在 `/Users/f/work/redmi-k50ultra/liuqin-study/raw/stock/`）；对方仓库的指纹栈源码与内核补丁
> （子任务逐文件精读，文中给出 `文件:行`）；我们的 7.2.10 源码树。标“评估”的是判断，不是事实。

## 1. 结论

1. **两台机器的指纹芯片不是同一家的。** liuqin 用 FPC（`fingerprint_fpc`、`fpc,fpc1020`），diting
   用 Goodix 光学屏下指纹（`fingerprint_goodix`、`goodix,fingerprint`）。对方做成的整套方案
   **不能直接拿来用**：传感器驱动、TA、命令协议都是 FPC 专属的。
2. **diting 的指纹栈可以逆向，但没有现成的。** 原厂驱动 `goodix_fod.ko` 的 ABI 清楚（字符设备 +
   `GF_IOC_*` ioctl + netlink 中断通知，不碰 SPI）；两个 TA（`fingerpr`、`gfdit`）在 `modem_a`
   里，**是未加密的 ARM64 代码**，字符串可读。但这一代 Goodix TA 与已知开源实现针对的 `gfenu`
   不是同一套，协议得自己推。
3. **一个必须纠正的认识**：上游 7.2.10 的 QSEECOM **不能**靠“加白名单”给用户态用。它只导出了
   `qcom_scm_qseecom_app_get_id` / `qcom_scm_qseecom_app_send` 两个内核内符号，没有 listener、
   没有 TA 加载、没有用户态设备。指纹要的“用户态加载 TA + listener 服务”在 7.2.10 里不存在，
   得移植一套 QSEECOM TEE 驱动。
4. **更直接的参考不是 liuqin，而是同一个 QSEECOM 驱动作者的 Goodix 项目**
   [`wrobelda/goodix-fp-spi-linux`](https://github.com/wrobelda/goodix-fp-spi-linux)：内核侧的
   QSEECOM TEE 驱动、Goodix 传感器驱动（netlink 中断）、supplicant、libfprint 驱动都是现成的，
   据称基于 v7.1。它能覆盖 diting 的大部分基础设施；未知的是 diting 的 TA 协议。
5. 可借鉴 liuqin 的：QSEECOM 用户态 ABI 的设计、TA 加载与固件路径的处理、RPMB / Gatekeeper
   凭据流程、fprintd 的自适应模板补丁、polkit / systemd / PAM 的接法，以及它记录下来的
   “会把机器搞挂”的失败模式。

## 2. diting 的指纹硬件

原厂 `dtbo_b` 有 44 个覆盖层，第 2 项是 "Diting based on Qualcomm Technologies, Inc SM8475"：

```devicetree
fragment@34 {
        target = <&soc>;
        __overlay__ {
                fingerprint_goodix {
                        compatible = "goodix,fingerprint";
                        l1c_vdd-supply = <&L1C>;     /* 1.8 V */
                        l3c_vdd-supply = <&L3C>;
                        goodix,gpio-reset = <&tlmm 41 0>;
                        goodix,gpio-irq = <&tlmm 40 0>;
                        status = "ok";
                };
        };
};
```

节点里只有供电和两个 GPIO，没有 SPI 控制器引用。顺带一提，这两个引脚号和 liuqin 的 FPC 一样
（中断 40、复位 41，见 §5.6）。

同一个 dtbo 里其它机型的对照：liuqin（第 15 项）有 `fingerprint_fpc`、`fpc,fpc1020`；
yudi（第 34 项）、unicorn、thor、zeus 等用 `goodix,fingerprint`。小米在 SM8475 上两种都用。

### 2.1 原厂内核驱动的 ABI（从二进制的字符串看）

原厂 `vendor_boot_b` 的 ramdisk 里有 355 个内核模块。指纹相关的是 `goodix_fod.ko`（55 KB，
ELF64 ARM64，未 strip）。（`goodix_core.ko` 是 Goodix **触控**的核心驱动 `goodix_ts_core`，与
指纹无关。）`strings goodix_fod.ko` 里能读出：

| 类别 | 内容 |
| --- | --- |
| 模块信息 | `name=goodix_fod`，`description=fingerprint sensor device driver`，`license=GPL v2` |
| compatible | `goodix,fingerprint`、`goodix,gpio-irq`、`goodix,gpio-reset` |
| 设备 | 字符设备（`gf_class`、`gf_fops`、`SPIDEV_MAJOR`、"No device for minor %d"）和 input 设备 `uinput-goodix` |
| ioctl | `GF_IOC_INIT`、`GF_IOC_ENABLE_POWER`、`GF_IOC_DISABLE_POWER`、`GF_IOC_RESET`、`GF_IOC_ENABLE_IRQ`、`GF_IOC_DISABEL_IRQ`、`GF_IOC_ENTER_SLEEP_MODE`、`GF_IOC_CHIP_INFO`、`GF_IOC_GET_FW_INFO`、`GF_IOC_NAV_EVENT`、`GF_IOC_EXIT`、`GF_IOC_REMOVE` |
| 中断 | `gf_irq`、`request_threaded_irq`、`netlink_kernel_create`、`netlink_unicast`、"send msg from kernel to usespace failed"、"create netlink socket error" → **中断经 netlink 通知用户态** |
| 手势 | nav click / double click / long press / left / right / up / down / finger down / up，经 uinput 报成按键 |
| 电源与复位 | `gf_power_on` / `gf_power_off`、`gf_hw_reset`、pinctrl（"Pin state[default] not found"）、regulator（"of vreg successful found"） |
| SPI | 只有 "Failed to register SPI driver." 和一个 `gx_match_table`，**没有任何 SPI 传输符号** |

所以原厂设计是：**内核驱动只管上下电、复位、中断和手势；指纹数据和匹配都在 TA 里，SPI 总线归
安全世界**。这与 `wrobelda/goodix-fp-spi-linux` 重写的 OEM 驱动是同一个 ABI（它同样“拥有
regulator、reset 和 interrupt，经 netlink 上报中断，不访问 SPI 总线”）。

构建服务器上的小米原厂内核源码（`~/k50ultra/vendor-kernels/xiaomi-diting`）里**没有**
Goodix 驱动的源码（`find` / `grep` 都没有命中），只能看二进制。

### 2.2 diting 的 TA

`modem_a`（`/dev/sde7`，vfat，380 MB）的 `/image/` 下有 367 个文件，其中两个是指纹 TA：

| TA | 文件 | 总大小 | `b01` 开头 | 可读字符串（≥ 6 字符） |
| --- | --- | --- | --- | --- |
| `fingerpr` | `fingerpr.mdt` + `b00`–`b08` | 11 016 461 字节，md5 `91f25df9…` | `f07bbfa9 d0340090 …`（AArch64 指令） | 13 873 条 |
| `gfdit` | `gfdit.mdt` + `b00`–`b08` | 15 270 936 字节，md5 `39c65a46…` | 同上 | 8 630 条 |

两个都是**未加密的 ARM64 代码**。字符串特征：

- `fingerpr`：`tz_app_cmd_handler`、`GPAppLib_init`、`cmnlib_init`、`qfp_initialize_finger_detection`、
  `qfp_finger_detection_v2`、`bge_engine_calibration`、`bge_database_*`、`QFSversion`。这是高通
  QFS 那一套的符号。
- `gfdit`：`gf_event_bus`、`gf_product_module`、一长串 `GF_ERROR_*`（`GF_ERROR_SPI_TRANSFER_ERROR`、
  `GF_ERROR_NOT_MATCH`、`GF_ERROR_OPEN_TA_FAILED`…）、构建路径
  `/workfolder/work/g3s_public/fingerprint2/customized/goodix/shenzhen_public_standard/ta/extmodules/…`。
  这是 Goodix 自己的 TA（"g3s"、深圳定制）。

两者的分工（哪个负责匹配、哪个负责驱动传感器）从字符串判断不了，要读代码或抓原厂 HAL 的
调用才知道。旁边还有 `mldapta`、`mlipay`（小米支付相关）。

对照：liuqin 的是 `fpcliu`，`wrobelda` 支持的是 `gfenu`（小米平板 5 Pro 5G，SM8250，Goodix
GF3626）。三个名字三种型号。

## 3. 我们现在的状态

- 设备树里没有指纹节点，没有 fprintd / libfprint 包。
- `/dev/tee0` 存在，`qcomtee` 模块已加载（dmesg `qcomtee: QTEE version 0.0.0`）。
- `.config`：`CONFIG_TEE=y`、`CONFIG_QCOMTEE=m`、`CONFIG_QCOM_QSEECOM=y`、
  `CONFIG_QCOM_QSEECOM_UEFISECAPP=y`、`CONFIG_EFI=y`。
- dmesg：

  ```
  qcom_scm firmware:scm: qseecom: found qseecom with version 0x1402000
  qcom_scm firmware:scm: qseecom: untested machine, skipping
  ```

### 3.1 上游 7.2.10 的 QSEECOM 到底有什么

到源码里核对的结果（`drivers/firmware/qcom/qcom_scm.c`）：

- 导出给其它驱动的只有 `qcom_scm_qseecom_app_get_id` 和 `qcom_scm_qseecom_app_send`
  （`EXPORT_SYMBOL_GPL`，2231 和 2283 行）。
- `qcom_scm_qseecom_allowlist[]`（2289 行起，asus、dell 等机器，没有 sm8450 / sm8475 / diting）
  只决定要不要注册一个平台设备 `qcom_qseecom`（2366 行 `platform_device_alloc("qcom_qseecom", -1)`）。
  这个设备的唯一使用者是 `qcom_qseecom_uefisecapp.c`（UEFI 变量）。注释：
  “We do not yet support re-entrant calls via the qseecom interface. To prevent any potential issues
  with this, only allow validated machines for now.”
- `drivers/tee/` 下只有 `amdtee`、`optee`、`qcomtee`、`tstee`。没有 QSEECOM TEE 驱动，没有
  `/dev/teepriv`，没有 listener。

所以白名单对我们没有意义（手机没有 EFI 变量的需求），**要让用户态用 QSEECOM 必须移植一套
TEE 驱动**。这一节纠正了我早先“加白名单就行”的说法。

## 4. liuqin 的指纹栈

路径前缀：`M/` = `liuqin-study/raw/mainline/`，`O/` = `M/device/fingerprint/oem/`，
`P/` = `liuqin-study/raw/patches/`。

### 4.1 分层

| 层 | 组件 | 事实 |
| --- | --- | --- |
| 内核：传感器控制 | `fpc1264_spi_diag`，misc 设备 `/dev/fpc1020` | 管 VDD、复位、中断；只在读硬件 ID 时用 SPI |
| 内核：QSEECOM | `P/0275`（SCM 的 TA 加载 / 关闭 / listener）、`P/0276`（把分段镜像拼成一个 blob）、`P/0277`（TEE 驱动，`TEE_IMPL_ID_QSEECOM = 5`） | `P/0274` 是 TEE `close_context` 操作的回移 |
| OEM TA | `fpcliu`（`fpcliu.mdt` + `b00`–`b08`） | 需要时由 Linux 加载 |
| 常驻 TA | `keymaster64` | 按名字解析，Linux 从不加载它 |
| listener 守护进程 | `qsee-supplicant`（FS 10、GPFS 0x7000）、`liuqin-rpmb-supplicant`（加 RPMB 0x2000） | 每次操作时由 Python 启动，结束时停掉 |
| TA 客户端 | `fpc_build_info`（FPC 协议）、`qsee-gatekeeper`（Keymaster / Gatekeeper，生成 HAT）、`pam-input`（旧路径） | 静态链接的 ARM64 |
| 胶水 | `oem_runtime.py`、`authorize_oem.py`、`native_credentials.py`、`native_enrol.py` | MIT |
| libfprint | TOD 驱动 `libfprint-tod-fpc1264-oem.so`（虚拟设备 `fpc1264_oem`） | 基于 libfprint 1.95.1+tod1，不替换系统的 libfprint |
| fprintd | 私有构建的 fprintd 1.94.5 加一个自适应模板补丁 | 装在 `/usr/local/lib/liuqin-fpc-oem/fprintd` |
| 集成 | `liuqin-fpc-stable-module.service`、fprintd drop-in、polkit 规则、modprobe 黑名单 | PAM 用发行版的 `libpam-fprintd` |

验证范围：一个账户、一枚手指、一台 256 GB 机器、内核 `6.17.0-rc1-gfe81794b5e1b`。挂起恢复、
冷启动、与 Android 安全存储的共存都没有结论（`O/README.md:213-219`）。

### 4.2 TA 从哪来、怎么加载

- **来源**：小米平板 6 Pro 的 HyperOS `OS2.0.6.0.VMYCNXM`，`images/NON-HLOS.bin` 的 `/image`
  目录（`O/firmware/NOTICE:3-5`）。
- **首次开机**：`provision_firmware.py` 只读挂载 `/dev/disk/by-partlabel/modem_a`，只拷那 10 个
  文件，逐个对照 `O/firmware/SHA256.json`（`O/src/fingerprint/deployment/provision_firmware.py:18-19,52-67`）。
  镜像缺失或不同就禁用指纹启动，不碰分区（`O/README.md:130-137`）。
- **加载**：`oem_runtime.py` 把固件目录写进
  `/sys/module/firmware_class/parameters/path`；内核 `request_firmware("<名字>.mdt")` 加各段
  （`P/0277:1684-1686`）；mdt 与各段按程序头顺序拼成一个 blob，放进 4 MiB 对齐的 TZ 内存，
  上限 16 MiB；再调 `qcom_scm_qseecom_app_load`（`P/0275:442-488`）。
- **谁加载**：`fpc_build_info` 打开特权设备，开一个名字为 `fpcliu` 的会话（TA 不在就加载）
  （`fpc_build_info.c:1182-1194`）。
- **生命周期**：最后一个会话引用关闭时 TA 卸载；重启前 TZ 拒绝第二次加载
  （`P/0277:583-608`、`P/0275:490-497`）。
- **许可**：OEM 二进制不随包分发，项目没有获得再分发许可（`O/firmware/NOTICE:7-8`）。

diting 上同理：TA 从本机的 `modem_a` 取（§2.2），不分发。

### 4.3 FPC 协议（说明逆向出来的是什么样子）

- **会话**：`TEE_IOC_OPEN_SESSION`，UUID 全零，一个输入 memref 里是 NUL 结尾的 TA 名字。
- **调用**：`TEE_IOC_INVOKE`，`func=0`，四个参数：64 字节请求（字 0 是长度）、64 字节应答
  （字 0 是 `int32` 状态）、一对 `(4, 4)` 值参数和一个 4096 字节载荷（内核把载荷物理地址写进
  请求偏移 4）。
- **载荷**：字 0 是命令组，字 1 是子命令，数据从 +8 开始。

| 组 | 内容 |
| --- | --- |
| 12 | build info（JSON） |
| 10 | 传感器：初始化 10/0、睡眠 10/5、OTP 10/6、手指按下 / 离开 / 状态、采集 10/4 |
| 11 | 生物识别：bio init、载入空库、设活动组、录入 11/1–11/3、识别 11/4、更新模板 11/5、模板计数、认证器 ID |
| 3 | 硬件认证：init、录入挑战、授权、设操作 ID、取认证结果（69 字节 HAT） |
| 4 | 模板库导入导出（4080 字节分块） |
| 5 | 自检、未校准采集 |

来源 `fpc_build_info.c:472-565, 613-657, 756-785, 907-994`。这个命令集完全是 FPC 的，对
diting 没有直接用处。

### 4.4 认证链

- Gatekeeper 在 `keymaster64` TA 里，客户端是 `qsee_gatekeeper.c`：请求是 u32 命令加 CBOR
  映射，应答是 i32 状态、u32 长度加 CBOR。
- 命令：`0x200` / `0x207` 版本协商（期望 API 4.1、TA ≥ 4.540）；`0x205` 取硬件认证 blob；
  `0x220e` / `0x220f` 共享 HMAC 探测；`0x21001` Gatekeeper 录入（返回 58 字节 handle）；
  `0x21002` Gatekeeper 验证（拼成 69 字节 HAT）。
- 普通世界从不签名，只检查 HAT 的版本和挑战字段。

**这一层最有复用价值**：diting 的机器上也应该有 `keymaster64`，但命令号、CBOR 标签、API
版本、handle 长度都是从 liuqin 固件里恢复出来的，得在 diting 上重新确认。

### 4.5 凭据与存储

- **机器凭据**：root 专属的 32 字节随机密钥加 Gatekeeper handle，放在
  `/var/lib/liuqin-fingerprint/native-enrollment/<uid>/`。原生 UID 是 `0x60000000 | linux_uid`，
  不从 Linux 密码派生（`O/README.md:57-63`）。
- **模板**：fprintd 存成序列化的 `FpPrint`，其中是不透明的 TA 数据库。
- **RPMB**：listener `0x2000`，经 SG_IO 转到 UFS RPMB，设备路径 `/dev/bsg/0:0:0:49476`
  **写死成 liuqin 的拓扑**（`O/src/third_party/qsee-supplicant/src/rpmb_ufs.c:20-22, 64-65`）。
  不编程序密钥，假定原厂栈已经做过。
- 写操作都要求 `--ufs-rpmb-authenticated`。

### 4.6 内核驱动的 ABI（`P/0278`、`P/0281`）

```dts
&spi10 {                                  /* QUPv3 wrapper 1, third SE, spi@a88000 */
	status = "okay";
	fingerprint@0 {
		compatible = "fpc,fpc1020";
		reg = <0>;
		spi-max-frequency = <8000000>;
		interrupt-parent = <&tlmm>;
		interrupts = <40 IRQ_TYPE_EDGE_RISING>;
		reset-gpios = <&tlmm 41 GPIO_ACTIVE_LOW>;
		vdd-supply = <&pm8350c_l9>;
		pinctrl-0 = <&fingerprint_irq>, <&fingerprint_rst>;
	};
};
```

- `open`：第一次打开时使能 VDD、翻转复位（拉低 10 ms、释放、等 20 ms）、使能中断；最后一次
  `close` 反过来。
- `poll()`：每个中断沿报一次 `EPOLLIN`。
- ioctl：`FPC_IOC_RESET`（`_IO('f', 1)`）、`FPC_IOC_GET_HWID`（`_IOR('f', 2, __u16)`，经 SPI
  读寄存器 `0xFC`）。
- sysfs：`hw_id`、`irq_count`、`power_state`、`reset`。
- **SPI 由 TA 完成**，用户态只 open / poll / close `/dev/fpc1020`；内核驱动不调任何 SCM / TEE。
- 中断不需要 `qsee_ipc_irq_bridge` 那样的桥：普通世界轮询设备节点，自己去取指纹按下事件，
  然后命令采集。

### 4.7 用户态 TEE ABI（`P/0277`）

- 客户端设备：`open_session` 用全零 UUID 加一个 memref 名字；`invoke` 要 `func=0`，2–10 个
  成对参数。
- 特权设备（需要 `CAP_SYS_ADMIN`）：第一个参数是 memref 时加载 `<名字>.mdt`；是值参数时注册
  listener。
- listener 投递：`TEE_IOC_SUPPL_RECV` 返回 listener id、代数值和缓冲区，`TEE_IOC_SUPPL_SEND`
  回带代数值。同一时刻只有一个接收者，10 秒超时。

**源码里记下的失败模式**（移植到 diting 前必须知道）：

- 请求里的“已打补丁地址”字段为 0 会**复位机器**（`P/0277:955-957`）。
- listener 请求没人应答，TA 就停住，之后所有调用返回 `-EBUSY` 直到断电（`P/0275:16-22`）。
  对方的补丁让未知 listener 直接回失败。
- listener 回成功但没填缓冲区，“观察到安全世界挂死直到看门狗”（`P/0275:633-636`）。
- 一次 listener 等待会让所有 QSEECOM 用户阻塞最多 10 秒（`P/0277:301-307`）。

## 5. 对 diting（Goodix）什么能复用

| 组件 | 结论 | 原因 |
| --- | --- | --- |
| `qsee-supplicant`（FS 10、GPFS 0x7000） | 原样复用 | 与传感器无关 |
| `liuqin-rpmb-supplicant` | 核对常量后复用 | UFS 路径写死成 liuqin |
| `qsee_gatekeeper.c` | 确认 diting 的 `keymaster64` 后复用 | 命令号等来自 liuqin 固件 |
| `hw_auth_token.h` | 原样复用 | AOSP 定义 |
| `native_credentials.py`、`native_enrol.py` | 大部分复用 | 录入的最后一步调用 FPC 客户端 |
| `oem_runtime.py`、`authorize_oem.py` | 改造 | 写死 `/dev/fpc1020` 和 `spi1.0` |
| `fpc1264-oem.c` | 重写传感器部分，保留骨架 | 状态语法和退出码跟着 FPC 客户端 |
| `fpc_build_info.c` | 整个重写 | 每个命令号都是 FPC 的 |
| 内核驱动 | 重写成不带 SPI 的 platform 驱动 | diting 的节点是 `goodix,fingerprint`，没有 `reg` / `interrupts` |
| fprintd 补丁 | 改驱动名；只在 Goodix 也用不透明库时才需要 | 两者都以 `"fpc1264_oem"` 为键 |
| polkit 规则 | 原样复用 | |
| TA 文件、`SHA256.json` | diting 专属 | 必须来自 diting 自己的分区 |
| Goodix TA 协议 | **缺** | 这些源码里没有 |

两个移植陷阱（源码里写明的）：

- 对方的单元和 drop-in 假定 QSEECOM 设备是 `tee0`。C 客户端会扫 `/dev/tee0..7` 找
  `impl_id == 5`，所以能适应；但 `stable_module.py` 的检查会错把别的设备当成通过。diting 上
  `tee0` 已经被 `qcomtee` 占了。
- 对方的驱动从 `interrupts` 取中断号；diting 的节点只有 `goodix,gpio-irq`。

## 6. 更直接的参考：`wrobelda/goodix-fp-spi-linux`

- **存在性**：WebSearch 确认该仓库存在，自述 “Driving Goodix SPI fingerprint sensors on Linux.
  The Linux stack contains two kernel interfaces, a machine-wide QSEECOM supplicant and application
  loader, a libfprint driver used by fprintd and GDM.”
- **与 liuqin 的关系**：对方自带的 `qsee-supplicant` 的 README 写着它需要
  “the QSEECOM TEE driver provided by `goodix-fp-spi-linux`”（`O/src/third_party/qsee-supplicant/README.md:43-47`）。
  liuqin 的 QSEECOM 驱动提交里也保留了原作者的版权。也就是说 liuqin 的内核 TEE 部分就是从这个
  项目来的。
- **内容**（子任务在线读取该仓库页面所得，细节请到仓库复核）：`wrobelda/linux` 的分支
  `qcom-qseecom-tee`（`CONFIG_TEE_QSEECOM`）和 `goodix-fp-spi`（`CONFIG_INPUT_GOODIX_FP_SPI`，
  `drivers/input/misc/goodix_fp_spi.c`），据称基于 v7.1；libfprint 驱动在 `wrobelda/libfprint` 的
  `goodix-qsee` 分支。参考设备是小米平板 5 Pro 5G（enuma，SM8250），Goodix GF3626，TA `gfenu`；
  屏下 GW 系列列为未测试。协议是 128 字节请求头、命令体在载荷 +100 处，类 1 命令 1000 detect、
  1001 init、1005 init finished、1006 pre-enrol、1007 enrol、1008 post-enrol、1010 authenticate、
  1012 save、1013 remove、1014 set active group、1015 enumerate、1016 IRQ pump、1017 / 1018 screen
  on / off、1086 authenticate finish、1089 get dev info；只观察到 FS 10 和 GPFS 28672 两个
  listener。许可 GPL-2.0-only。
- **对 diting 的意义**：内核侧（QSEECOM TEE 驱动、Goodix 传感器驱动）是 v7.x 形态的，比 liuqin
  的 6.17 补丁更接近我们的 7.2.10。TA 协议是 `gfenu` 的；diting 的 `gfdit` / `fingerpr` 是另一代
  （构建路径里有 `g3s_public/fingerprint2`），命令集可能不同，要自己核对。

## 7. 建议的实验顺序（评估）

0. **静态侦察**（已完成一部分）。原厂驱动的 ABI、TA 的位置和可读性都确认了。还差：从 `super`
   分区里取出原厂指纹 HAL，看它开的是哪个 TA、发的是什么命令头。对方当初也是这么做的
   （“Exact command headers copied from the OEM HAL entry points”，`fpc_build_info.c:470`）。
   我们仓库里有 Android super 解析工具。
1. **拿到 QSEECOM TEE 驱动**。两条路：取 `wrobelda/linux` 的 `qcom-qseecom-tee` 分支（v7.1
   形态），或者移植 liuqin 的 `0b5cd921fb52`、`e8f8cc13bcb7`、`ea63b921c92c`、`6640846b3b6e`。
   前者更接近。
2. **只做电源和中断**。按 diting 的原厂节点写一个 platform 驱动（L1C 1.8 V、L3C、复位 41、
   中断 40，netlink 或 `poll()` 上报中断），加 `interrupts` 或解析 `goodix,gpio-irq`。验收：
   电轨电压对，手指按上去中断计数增加。
3. **验证 TEE 活着，但不碰指纹 TA**。跑 `qsee-supplicant`，应看到两条
   `event=listener_registered`；只发版本查询（`0x200`）问 `keymaster64`。对方的 README 明确
   警告不要做试探性的初始化（`O/README.md:94-97`）。
4. **加载 Goodix TA**。用 `qsee-app-loader <名字>` 加载 diting 自己的 `fingerpr` / `gfdit`，
   listener 先跑起来。签名被拒会报错，不致命。
5. **发第一条无害命令**。按住传感器节点，发 Goodix 的 build info 或 detect，看 TA 需要哪些
   listener 服务。
6. **录入放最后**。它会写 Gatekeeper 和 RPMB 状态，Android 也用这些。先备份。

不建议从“经 SPI 探芯片 ID”开始：原厂驱动的 SPI 在安全世界，普通世界碰不到总线；对方的
README 还留着 GENI 故障未解决的记录。

## 8. 许可

| 组件 | 许可 |
| --- | --- |
| 项目脚本和 Python 胶水 | MIT（`M/LICENSE`、`M/NOTICE:4`） |
| `fpc_build_info.c`、`qsee_gatekeeper.c`、`pam-input.c` | BSD-2-Clause |
| `fpc1264-oem.c`、`fpc-oem-print.c` | LGPL-2.1-or-later |
| fprintd 适配 | GPL-2.0-or-later |
| `hw_auth_token.h` | Apache-2.0（AOSP） |
| `qsee-supplicant` | BSD-2-Clause；`qsee_protocol.h` BSD-3-Clause-Clear |
| 内核 FPC1264 驱动 | GPL-2.0-only |
| 内核 QSEECOM TEE / SCM / mdt loader | GPL-2.0-only，Dawid Wróbel 的版权保留 |
| OEM TA | 专有，不再分发 |

## 9. 取证方法（可复用）

- `vendor_boot` 头是 `VNDRBOOT`，v4。头部 2128 字节，ramdisk 紧跟第一页，DTB 在 ramdisk 之后的
  页边界。`liuqin-study/scripts/vb_dtb.py` 可以直接从镜像里取 DTB。
- 本地 `device-data/images/vendor_boot_a.img` 是**我们自己构建的** vendor_boot（cmdline 是
  `root=PARTLABEL=userdata ... diting.debug=usb`），不是原厂的。原厂的在手机的 `vendor_boot_b`。
- `vendor_boot_b` 的 DTB 区是 13 个 SoC 基础 DTB，板级内容在 `dtbo` 里。SM8475 = Diwali。
- `dtbo` 是 Android DTBO 格式（magic `0xd7b7ab1e`，头部 32 字节，每项 32 字节）。
- 从 ramdisk 取模块用 `liuqin-study/scripts/cpio_extract.py`（macOS 的 `cpio` 不支持
  `--to-stdout`）。对取出的 `.ko` 只用 `strings` / `file`，不要执行。
- `modem_a` 可以只读挂载：`mount -o ro,nosuid,nodev,noexec /dev/disk/by-partlabel/modem_a /mnt/x`。
