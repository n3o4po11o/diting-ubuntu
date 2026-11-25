# liuqin 内核提交审计：哪些我们已有，哪些值得拿

> 对方内核：`https://github.com/yzddmr6/linux-sm8450-liuqin.git`，分支 `liuqin-6.17`，
> HEAD `ed0dad5d20d0`（2026-11-16）。Makefile 是 6.17.0-rc1，基于 sm8450-mainline/linux
> （`a19585977c11`）。对方的 rootfs 仓库在 `kernel/source.json` 里锁定内核提交
> `c25f056e0c20e7a9fd0632598909568005fdfc56`。自 6.17-rc1（`8f5ae30d69d7`）以来共 348 个非合并
> 提交。标签：v0.6.1、v0.6.2、v0.7.0、v0.8.0。
> 我们的树：`~/k50ultra/diting-ubuntu/ubuntu-diting/work/kernel-src`（7.2.10 + 105 个补丁）。

## 1. 结论

对方真正值得我们拿的东西集中在下面这些，按“小、低风险、正对我们的已知问题”排序：

| 序 | 提交 | 改动量 | 对应我们的问题 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | `b9e43fbe6b23` a6xx: 启动 GMU 前屏蔽 HFI 中断 | 3 行 | GMU 超时后黑屏 | 上游已合并（晚于 7.2.10）；严格检查可直接套用 |
| 2 | `cb8be68ec106` a6xx: HFI 中断只清 CM3 fault 位 | 7 行 | 同上，提交说明逐条描述了我们的症状 | 同上 |
| 3 | `355dd22d6a31` a6xx: 挂死恢复时强制冷启动 | 12 行 | “恢复后 GMU 不再初始化” | 不在上游；需手工移植（7.2 的上下文变了） |
| 4 | `960054da68da` clk: dispcc-sm8450 的 `disp_cc_mdss_mdp_clk_src` ops | 1 行 | 开机的 `rcg didn't update its configuration` 警告 | 上游已合并（晚于 7.2.10）；可直接套用 |
| 5 | `a32e4e25f6c0` clk: Lucid Ole PLL 已使能时跳过配置 | 9 行 | 点名 SM8475 的花屏 | 同上 |
| 6 | `594134933699` serial: qcom-geni 挂起期间屏蔽端口中断 | 几行 | 蓝牙走同一个 GENI 串口驱动 | 不在上游；可直接套用 |
| 7 | `5bbdbea6a307` rpmsg: glink 暂存端点就绪前到达的消息 | 一个函数 | 我们 T46 的 DSP 服务晚到 / 不到 | 不在上游；需手工移植（7.2 的上下文变了） |
| 8 | `787d0f7bf966` power: 修正 SM8475 电量单位 | 69 行 | `charge_counter` 是 mAh、`power_now` 是占位值 | 依赖对方的 SM8475 变体，需要手工移植 |
| 9 | 充电整组：SM8475 变体、XM 传输、小米认证接口、电脑口 500 mA、QC 报 DCP、电量计刷新 | 约 1500 行 | 没有快充认证，`usb_type Unknown` | 需要人工移植并重新推导属性编号 |
| 10 | `9bc411d03020` DSI 错误路径、`03b536ad4e2c` `msm_gem_submits` 的 vmalloc 回退、`8ec7416f90f6` DPU 恢复前的 OPP 投票 | 都很小 | 预防性 | 可直接套用 |

不建议移植的：上游 7.2.10 已经有的（§3 表里 `IN` 的 20 个）；DP Alt Mode 整串和 liuqin 的 dts
（硬件不支持）；QSEECOM 那四个补丁按原样（上游有自己的版本，而且指纹需要的是另一套，见
FINGERPRINT.md）；对方那套 SM8450 iris 平台数据（我们有自己的且已验证）。

## 2. 方法与局限

三层判断，由粗到细：

1. **补丁法**（`liuqin-study/scripts/check-upstreamed.sh`）：把 348 个提交 `git format-patch`
   出来，对每个提交在我们的源码树上做 `patch -p1 -R --dry-run`。反向能套 = `PRESENT`，反向不行
   而正向能套 = `ABSENT`，都不行 = `CONFLICT`。模糊度 2 行时是 131 / 49 / 168；**模糊度 0 时是
   100 / 30 / 218**。模糊度 2 会产生假阳性：`1ffc4b5ff464`（a7x 的 `gx_is_on`）和
   `b8f84456a316`（dwc3 角色的用户态控制）都被判成“我们没有”，实际 7.2.10 里都有，只是函数
   被重构过。所以以零模糊度的 30 个为准。
2. **GitHub compare API**：对方有 33 个提交带着 `(cherry picked from commit <上游哈希>)`。对每个
   上游哈希查 `gregkh/linux` 的 `compare/v7.2.10...<哈希>`：`behind` = 是 v7.2.10 的祖先（我们
   已有），`ahead` 或 `diverged` = 不在 7.2.10 里。这是确定性的。构建服务器上的上游仓库
   （`~/k50ultra/diting-ubuntu/kernel/upstream`）是**浅克隆**（只有 1 个提交），所以不能用
   `git merge-base`。
3. **源码核对**：对候选逐个到 7.2.10 的源码里 grep（§5 各节注明）。

原始结果：`liuqin-study/raw/upstream-check.txt`（模糊度 2）、`upstream-check-strict.txt`
（模糊度 0）、`cherry-check.txt`（compare API），补丁副本 `raw/patches/`。

## 3. 上游提交的确定性判定（33 个摘樱桃）

**已在 v7.2.10 里（20 个）**：drm/i915、drm/xe、amdgpu 的 11 个上游修复；
`fe1db5d63ebd` PDC 睡眠序列；`1ffc4b5ff464` a7x 的 `gx_is_on`；`52750276dbc7` gemnoc workaround；
`058c7fab4e1f` retire 前先恢复硬件；`a58d5638fc55` hci_qca setup 失败清理；`c33ce60f2967`
rpmh-rsc；`547a7d531ec1` q6apm 图启动计数；`9bca23b2f51c` ucsi_glink UAF。

**不在 v7.2.10 里（13 个）**：

| 补丁 | liuqin 提交 | 上游哈希 | API 结果 | 含义 |
| --- | --- | --- | --- | --- |
| 0291 | `b9e43fbe6b23` | `2379434f8d3b` | ahead | 上游已合并，在 7.2.10 之后；可直接从上游取 |
| 0292 | `cb8be68ec106` | `812aa5346482` | ahead | 同上 |
| 0282 | `4320cc40084a` | `04854437df76` | ahead | 同上（battmgr 不做唤醒源） |
| 0331 | `9c741c403a4b` | `3dd68c8d03b1` | ahead | fastrpc 冻结；我们有等价的 0085 |
| 0344 | `960054da68da` | `8464e2284fec` | diverged | 上游已合并（lore 链接在提交里），不在 7.2.10 |
| 0345 | `a32e4e25f6c0` | `eb34e2804ce4` | diverged | 同上 |
| 0326 | `8ec7416f90f6` | `3a56ea9421bb` | diverged | 在一条主题分支上，没进主线 |
| 0327 | `b8fd29b1f39a` | `caab65c38df3` | diverged | 同上 |
| 0300 / 0301 | `2ebfc1448441` / `49ffc60e14de` | `b9b23e72abef` / `b05482e7ce1b` | diverged | LPASS macro 改 PM clock 的系列，没进主线 |
| 0307 | `e4a305e11437` | `5fbc7cbd11e2` | diverged | FROMLIST，未合并 |
| 0311 / 0312 | `f43a4aa7fa89` / `9bc411d03020` | — | 404 | 标注的上游哈希在 `gregkh/linux` 里不存在，按对方自己的补丁看待 |

## 4. 零模糊度下确认“我们没有、且能直接套用”的 30 个

与我们相关的（20 个）：

| 主题 | 补丁 |
| --- | --- |
| GPU | `b9e43fbe6b23`（0291）、`cb8be68ec106`（0292）、`fdf3c8b8b912`（0316，**不能单独上**，它读的 `gpu->wedged` 由 `018982b5e1ac` 引入）、`03b536ad4e2c`（0334） |
| 显示 | `960054da68da`（0344）、`a32e4e25f6c0`（0345）、`9bc411d03020`（0312 DSI）、`8ec7416f90f6`（0326 DPU） |
| 挂起 | `594134933699`（0315 GENI） |
| USB | `ccee5e821158`（0242 QMP SM8475 表）、`a610c157c1d0`（0244 UCSI PPM）、`9f9cd5ac3bc1`（0310）、`f43a4aa7fa89`（0311） |
| CPU dts | `1cd8848c870a`（0323） |
| LPASS | `b8fd29b1f39a`（0327）、`2ebfc1448441` / `49ffc60e14de`（0300 / 0301） |
| UFS | `68051cc5e986`（0189，unipro 850 MHz） |
| 电源域 dts | `ab77304a46a1`（0192，`LOW_SVS_L2` RPMhPD 档位） |
| 网络 | `e6604d01be72`（0269） |

与我们无关的（8 个）：selftests tls、sm8450-mainline 时代的别的机型（pinctrl 绑定、eusb2
repeater、mdss clock-names、NT37705 面板、uart20、defconfig）、对方仓库的 CI 配置。

零模糊度下变成冲突、但到源码里确认没有的：`355dd22d6a31`（0272，见 §5.1）、`5bbdbea6a307`
（0314 glink，`qcom_glink_native.c` 里没有 `pending_rx`）、整组 battmgr、`569f79be4a7d`（0238，
`qcom_q6v5_pas.c` 里没有 `slpi_auto_boot`）、`d54edba9153c`（0321）与 `309060c799a7`（0324，
`sm8475.dtsi` 里没有 `qcom,opp-cx-level` 和 BWMON 节点）、`40d6ee58b96e`（0322，`sm8450.dtsi`
的 `mdss_mdp` 没有第二个 RPMh 域）。

## 5. 逐主题精读

### 5.1 GPU / GMU：与“黑屏”已知问题对应的三个补丁

我们的 KNOWN_ISSUES 记录的症状：从空闲恢复时 GMU HFI 消息超时，GPU fault（CP 读 iova 0），
hangcheck 开始恢复；恢复跑完后 GMU 再也不初始化（"GMU firmware initialization timed out"），
屏幕停在黑屏直到重启。`cb8be68ec106` 的提交说明几乎逐条一样（"Timeout waiting for GMU OOB set
GPU_SET … hw_init() then fails, the GPU runs uninitialized (a CP fault at iova 0, ring 2) and
recovery hangs the display"）。它是 symptom 对 symptom 的匹配，是否同因要上机才知道。

**`cb8be68ec106` the HFI IRQ clears only the CM3 fault bit**（作者 gennro，来自 armada-os PR 662；
上游 `812aa5346482`）：

```c
 static irqreturn_t a6xx_hfi_irq(int irq, void *data)
 {
 	struct a6xx_gmu *gmu = data;
 	u32 status;
 
+	/*
+	 * Only clear what this handler deals with: the HFI response (MSGQ) and
+	 * OOB ack bits are polled for, and clearing them here loses the GMU's
+	 * answer to whoever is waiting for it.
+	 */
+	status = gmu_read(gmu, REG_A6XX_GMU_GMU2HOST_INTR_INFO) &
+		 A6XX_GMU_GMU2HOST_INTR_INFO_CM3_FAULT;
 	gmu_write(gmu, REG_A6XX_GMU2HOST_INTR_CLR, status);
 
 	if (status & A6XX_GMU_GMU2HOST_INTR_INFO_CM3_FAULT) {
```

原因：处理函数把读到的所有位都清掉了，而 MSGQ 和 OOB 应答位是别人在 `gmu->lock` 下轮询的；
处理函数抢在轮询者前面跑，应答就丢了，轮询超时。我们 7.2.10 的 `a6xx_gmu.c:62-72` 仍是原样。

**`b9e43fbe6b23` mask the HFI interrupt before booting the GMU**（上游 `2379434f8d3b`）：

```c
 	/* Set the bus quota to a reasonable value for boot */
 	a6xx_gmu_set_initial_bw(gpu, gmu);
 
+	/* The mask resets to 0 with the GMU: keep HFI replies off the irq line */
+	gmu_write(gmu, REG_A6XX_GMU_GMU2HOST_INTR_MASK, ~0);
+
 	/* Enable the GMU interrupt */
```

原因：GMU 电源域关过之后 `GMU2HOST_INTR_MASK` 读回 0，`a6xx_gmu_resume()` 要到
`a6xx_hfi_start()` 之后才重新写它；在此之前每条 HFI 应答都会拉高中断线。中断此时是禁用的，
但只是“懒惰地”禁用，目标 CPU 如果在慢退出的空闲态，中断可能在 `enable_irq()` 之后才送到，
处理函数就在 `a6xx_gmu_set_initial_freq()` 和 GPU_SET OOB 等同一个寄存器里的位的时候跑起来。
我们 7.2.10 里唯一的 `INTR_MASK = ~0` 写入在 `a6xx_gmu_irq_disable()`（`a6xx_gmu.c:1091`），
恢复路径上没有。

**`355dd22d6a31` force cold boot on hang recovery**（作者 yp，不在上游）：

```c
+	/*
+	 * On the recovery path the CX power domain has been cycled, which can
+	 * clear the CM3's TCM even though the TCM-retention flag read above
+	 * still reports "retained". Taking the warm-boot path in that case
+	 * skips the firmware reload, so the CM3 boots from dead memory and
+	 * never acks the host OOB handshake, leaving the GPU stuck in a
+	 * hang -> recover -> hang loop. Force a cold boot (full firmware
+	 * reload and re-init) whenever we are recovering from a hang.
+	 */
+	if (a6xx_gpu->hung)
+		status = GMU_COLD_BOOT;
+
 	ret = a6xx_gmu_fw_start(gmu, status);
```

7.2.10 里 `a6xx_gpu.h:119` 有 `bool hung;`，`a6xx_gmu_resume()` 里 `GMU_COLD_BOOT` 的判定在
`a6xx_gmu.c:1358-1367`，没有 `hung` 分支。上下文行号变了，要手工移植。

**其余 GPU 相关：**

- `018982b5e1ac`（0293）“stop replay and fail fences after A6xx recovery fails”：引入
  `gpu->wedged`、`msm_gpu_fail_submits()`、`a6xx_recover_suspend()`；恢复失败就把 GPU 标成
  wedged，停掉 hangcheck 和重放，在确认 CX 塌缩之后让硬件 fence 以 EIO 失败。配套的
  `fdf3c8b8b912`（0316）让 `msm_gem_close()` 可中断地等待。合起来的效果是把我们“phoc 卡在 D
  状态直到重启”变成干净的 GPU 失效加 EIO。六个文件的前向移植。
- `d54edba9153c`（0321）“send the GPU-dependent CX corner”：绑定 `qcom,opp-cx-level`，A730 的
  性能表里每个 GX OPP 带一个 CX 依赖档位。**但 liuqin 的表（12 档到 818 MHz）和我们的
  （0013，13 档到 900 MHz）不同**，要用得自己算 CX 列。
- `40d6ee58b96e`（0322）“carry Cape display, serial engine and GPU operating votes”：
  `&mdss_mdp` 加第二个 RPMh 域 `MX` 及配套的 `required-opps`；`dpu_kms.c` 和
  `i2c-qcom-geni.c` 在 `power-domains` 多于一个时挂上域列表。改的是 `sm8475.dtsi` / 
  `sm8450.dtsi`，对我们同样适用。我们 7.2.10 的 `sm8475.dtsi` 里没有这些。
- `309060c799a7`（0324）CPU / LLCC BWMON 节点（`0x19091000`、`0x190b6400`）加 `opp-peak-kBps`
  表。功耗调优的后续素材。
- `8ec7416f90f6`（0326）DPU：`dpu_kms_restore_core_clk_vote()` 在 `dpu_runtime_resume()` 的
  `clk_bulk_prepare_enable()` 之前重新投核心 OPP。对方的动机是 SM8750 上首次点亮会挂死 SoC；
  对我们是潜伏问题（CX 塌缩还没做到）。
- `03b536ad4e2c`（0334，Sam Day）`msm_gem_submit` 改用 `kvzalloc` / `kvfree`，上限
  `KMALLOC_MAX_SIZE`。针对 1 GiB 内存的板子，我们是预防性。
- `0301490788d9`（0273）只读的 `gpu_busy_percent` sysfs。调试用。
- 已在上游且我们已有的 a6xx 修复：`fe1db5d63ebd`、`44057d1b3eaf`、`52750276dbc7`、
  `1ffc4b5ff464`、`833b0525410c`、`058c7fab4e1f`、`1fccb137b380`、`ceba4ccedbe4`。

### 5.2 显示时钟

**`960054da68da`**（上游 `8464e2284fec`，lore `20260713-sm8450-qol-dispcc-v3`）：

```
 	.flags = CLK_SET_RATE_PARENT,
-	.ops = &clk_rcg2_shared_ops,
+	.ops = &clk_rcg2_shared_no_init_park_ops,
```

提交说明：“If the clock frequency is changed at registration time, a flicker will be visible at
boot.”我们 7.2.10 的 `dispcc-sm8450.c:616` 还是 `clk_rcg2_shared_ops`。它针对的正是我们开机
警告里的那个时钟；说明里讲的花屏我们没见到，能否消掉警告要上机看。

**`a32e4e25f6c0`**（上游 `eb34e2804ce4`）：

```c
+	/*
+	 * If the bootloader left the PLL enabled it's likely that there are
+	 * RCGs that will lock up if we disable the PLL below.
+	 */
+	if (trion_pll_is_enabled(pll, regmap)) {
+		pr_debug("Lucid Ole PLL is already enabled, skipping configuration\n");
+		return;
+	}
```

提交说明点名 “On some platforms such as SM8475 … graphical glitches when the mdss driver takes
over”。我们 7.2.10 的 `clk_lucid_ole_pll_configure()`（`clk-alpha-pll.c:2371-2383`）没有这个
判断。预防性。

**`9bc411d03020`**（0312，对方自己的）DSI：`pm_runtime_get_sync` 改 `pm_runtime_resume_and_get`
并加 `fail_put_pm` 标签；`xfer_prepare` 在运行时恢复、速率或链接时钟失败时停止。我们 7.2.10 的
`dsi_host.c` 仍有 4 处 `pm_runtime_get_sync`（220、2211、2544、2667 行）。

### 5.3 挂起与 DSP 链路

**`594134933699`** qcom-geni：`qcom_geni_serial_suspend()` 在 `uart_suspend_port()` 期间
`disable_irq()`，失败则重新使能；`_resume()` 在 `uart_resume_port()` 之后 `enable_irq()`：

```c
+	disable_irq(uport->irq);
+	ret = uart_suspend_port(private_data->drv, uport);
+	if (ret)
+		enable_irq(uport->irq);
+	return ret;
```

原因（提交说明）：`uart_suspend_port()` 先置 `suspended` 再停接收，`qcom_geni_serial_isr()`
对挂起的端口返回 `IRQ_NONE` 且不应答；`stop_rx()` 发出的取消接收的完成事件落在这个窗口里，
电平触发的中断就一直拉着，直到“nobody cared”把它永久禁用。liuqin 上这是蓝牙串口，进 s2idle
后蓝牙到重启前都是死的。我们的蓝牙同样走 `qcom_geni_serial`（补丁 0020），7.2.10 的
`qcom_geni_serial.c:1980-1994` 没有屏蔽；蓝牙能不能熬过挂起，我们的文档没有记录。

**`5bbdbea6a307`** glink：`struct glink_channel` 加 `pending_rx` 链表和
`qcom_glink_deliver_pending()`；`qcom_glink_rx_data()` 把完整消息先入队再投递，投递成功后才
归还 intent；端点没有回调或回调返回 `-EAGAIN` 时把消息留在链表上，等 `create_ept` /
`announce_create` 或后续消息到达时按序补投：

```c
+	list_for_each_entry_safe(intent, tmp, &channel->pending_rx, node) {
+		if (!channel->ept.cb)
+			return;
+
+		ret = channel->ept.cb(channel->ept.rpdev, intent->data,
+				      intent->offset, channel->ept.priv,
+				      RPMSG_ADDR_ANY);
+		if (ret == -EAGAIN)
+			return;
+
+		list_del(&intent->node);
+		intent->offset = 0;
+		qcom_glink_rx_done(glink, channel, intent);
+	}
```

提交说明：远端一拿到 intent 就可以发，而 `qcom_glink_create_ept()` 要等对端 ack 之后才设端点
回调，rpmsg 核心又在端点存在之后才 probe 驱动；落在这两个窗口里的消息会丢。QRTR 依赖不丢：
对端名字服务的 HELLO 一丢，两边就永远交换不了服务列表——在 Xiaomi Pad 8 Pro 上 26 次冷启动
有 1 次 ADSP 在跑、通道全开，但没有音频、充电器、传感器服务，直到下次重启。我们 T46 的现象
（服务 50 s 到 300 s 才应答或不应答）与之同类，是否同因是推断。7.2.10 的
`qcom_glink_native.c` 里没有 `pending_rx`。它改的是 glink 的核心接收路径，上机要测挂起和 DSP
重启。

`9c741c403a4b`（fastrpc 冻结）与我们的 0085 相同，不需要。

### 5.4 USB / Type-C

| 提交 | 改动 | 说明 |
| --- | --- | --- |
| `ccee5e821158` | `phy-qcom-qmp-combo.c` 加 `sm8475_usb3dpphy_cfg`（173 项 serdes / TX / RX / PCS 表），compatible `qcom,sm8475-qmp-usb3-dp-phy` | 用 sm8350 的表 PLL 永远锁不上，dwc3 每次 probe 都 “phy initialization timed-out”。7.2.10 的这个文件里没有 `sm8475` |
| `a610c157c1d0` | `ucsi_reset_ppm()`：先应答残留的 `ACK_COMPLETE` / `COMMAND_COMPLETE`，不再重发 `PPM_RESET`；`ucsi_init_work` 对 `-ETIMEDOUT` 也重试 | liuqin 的 ADSP PPM 每次尝试多出 261–414 次复位，UCSI 服务当次开机就废了 |
| `10bddb4202c8` | `qmp_combo_usb_power_on()` 先清 `SW_PWRDN` | PCS 一直留在复位 |
| `9f9cd5ac3bc1` | `pmic_glink_ucsi_register()` 只在成功时记 `ucsi_registered`（另一半是 KUnit） | 同步失败不应再安排重试。7.2.10 的 `ucsi_glink.c` 里已有 `ucsi_registered` 字段，形态不同 |
| `f43a4aa7fa89` | `ucsi_unregister()` 里 `ucsi->connector = NULL` | 下一次 init 提前失败时会解引用悬空指针 |
| `e6604d01be72` | `rtnl_fill_ifinfo()` 在父设备没有名字时跳过 `IFLA_PARENT_DEV_NAME` | USB 角色切换时 gnome-shell 里见过 oops |
| `b8f84456a316` | `dwc3_role_switch.allow_userspace_control = true` | **7.2.10 已有**（`drd.c:522`） |

对方 dts（`91d37cdb79e4`）：`&usb_1_dwc3` 改 `dr_mode="otg"`、`maximum-speed="super-speed"`、
两个 PHY，启用 `&usb_1_qmpphy`。其中**只有一条对 diting 有意义**：`5649815b7e60` 加的
`role-switch-default-mode = "host"`——UCSI 对不认识的对端报 `USB_ROLE_NONE`，否则会回落到
peripheral 并拆掉 xHCI。

USB3 和 DP 在 diting 上的硬件前提存疑，见 FEATURE_MATRIX §2.5。DP Alt Mode 那一串
（`8d5005650cfd`、`f7c302092be0`、`97044efd80ba`、`68783ed98722`、`95cf27cbc2e7` 等）不建议移植。

### 5.5 电池与充电（`qcom_battmgr`）

**整组是线性的**，按补丁号：
`0236 → 0249 → 0282 → 0318 → 0319 → 0320 → 0329 → 0330 → 0332 → 0335 → 0336 → 0337 → 0340 → 0341 → 0342 → 0343 → 0346 → 0347 → 0348`。
`0317`（四个热敏电阻）和 `0333`（关掉常投票的 QCE）是纯 dts。

| 补丁 | 提交 | 做什么 |
| --- | --- | --- |
| 0236（电池部分） | `2cd5a6f8ef67` | 加 `QCOM_BATTMGR_SM8475` 变体，由 `qcom,sm8475-pmic-glink` 选中；SM8475 的电池属性编号在 `BATT_TEMP` 起 +1；`CURRENT_NOW` 取反；`usb_type` 读 `USB_ADAP_TYPE`(7)；静默接受通知 `0x50`；加 XM 传输（`BATTMGR_XM_PROPERTY_GET 0x50` / `SET 0x51`）和只读的 `sm8475_raw` sysfs 组 |
| 0249 | `f2d5ed65ac03` | `xiaomi` 属性组：`request_vdm_cmd`、`verify_digest`、`authentic`、`slave_authentic`、`pd_verifed`、`adapter_id`、`adapter_svid`、`pdo2`、`fastchg_mode`、`apdo_max`、`power_max`、`bq2597x_*`、`real_type`、`current_state`；52 字节摘要帧 |
| 0282 | `4320cc40084a` | `psy_cfg.no_wakeup_source = true`（两个电源），否则每次充电器通知都唤醒 s2idle |
| 0318 + 0319 + 0320 | `966d59198cf6`、`737325522cd5`、`d927fe0e0532` | `xiaomi/thermal_level_requested`：往 `BATT_CHG_CTRL_LIM` 写 0–15 的**索引**；只在 liuqin 上出现 |
| 0329 | `01a5324ac9cd` | 通知设置加锁、`qcom_battmgr_stop_workers()` |
| 0330 + 0335 + 0336 + 0337 | `8511ab111c70`、`79ad9ad28f38`、`ac3d75c00557`、`3fe3a2068602` | 每秒读连接器 NTC（IIO），换成 0.1 °C 发给 ADSP；只在带电时采样；ADC 返回 `IIO_VAL_INT` 时不再当错误 |
| 0332 | `44c72b967ea6` | 外部电源变化时唤醒 s2idle |
| 0340 | `f4d672bbdaff` | 每 10 秒读一次 XM 属性 86 触发电量计刷新 |
| 0341 | `ea7c0a1abd52` | 对齐 M81 模块的 XM 属性编号（`XM_QUICK_CHARGE_TYPE 44`、`XM_APDO_MAX 45`、`XM_POWER_MAX 46`）；通知 0x50 发 uevent |
| 0342 | `787d0f7bf966` | 电量单位 |
| 0343 | `136081907242` | 接有线充电器时持有唤醒源 `qcom-battmgr-charge`（SDP / CDP 除外） |
| 0346 | `4775c39c1019` | KUnit 测试 |
| 0347 | `e5dcff1232de` | 电脑口取 500 mA |
| 0348 | `c25f056e0c20` | QC 充电器报成 DCP |

**`787d0f7bf966`**（修正电量单位；从 `Seeker0472/liuqin-nixos` 的提交 `1944c8474de8` 移植）：

```c
 static int qcom_battmgr_bat_charge_counter(struct qcom_battmgr *battmgr,
 					 union power_supply_propval *val)
 {
 	s32 counter = battmgr->info.charge_count;
 
+	/* Xiaomi reports the counter in mAh; full/design charge is already uAh. */
+	if (battmgr->variant == QCOM_BATTMGR_SM8475 &&
+	    check_mul_overflow(counter, MILLI, &counter))
+		return -ERANGE;
+
 	val->intval = counter;
 	return 0;
 }
```

并且对 SM8475 让 `POWER_NOW`、`TIME_TO_EMPTY_AVG`、`TIME_TO_FULL_AVG` 返回 `-ENODATA`，换成一个
只有 17 个属性的 `sm8475_bat_psy_desc`。提交说明：“Xiaomi's POWER_NOW is a fixed placeholder and
its time estimates are not in verified Linux ABI units.”我们在手机上读到的
`power_now = 10000000`、`time_to_full_avg = 60` 就是这类占位值（推断）。

**`e5dcff1232de`**（电脑口 500 mA）：让 `qcom-battmgr-usb` 的 `input_current_limit` 可写，每次
SDP 接入时内核写 500 mA：

```c
+	if (ua >= 0 && ua <= SM8475_ICL_IGNORE_UA)
+		return 0;
...
+	if (type != SM8475_USB_ADAP_SDP && type != SM8475_USB_ADAP_PD)
+		return -EINVAL;
+
+	return qcom_battmgr_usb_write_icl_locked(b, ua < 0 ? UINT_MAX : ua);
```

**`c25f056e0c20`**（QC 报 DCP）：SM8475 的 `USB_ADAP_TYPE` 把枚举从 0x80 往后扩了，
`usb_type` 读出来是 `-EINVAL`：

```c
+	case SM8475_USB_ADAP_HVDCP:        /* 0x80 */
+	case SM8475_USB_ADAP_HVDCP_3:      /* 0x81 */
+	case SM8475_USB_ADAP_HVDCP_3P5:    /* 0x82 */
+	case SM8475_USB_ADAP_HVDCP_3_CLASSB: /* 0x84 */
+		return POWER_SUPPLY_USB_TYPE_DCP;
+	}
+	return type <= POWER_SUPPLY_USB_TYPE_APPLE_BRICK_ID ? type :
+	       POWER_SUPPLY_USB_TYPE_UNKNOWN;
```

**多少是 liuqin 专属？** 驱动逻辑几乎全是通用的，靠 `variant == QCOM_BATTMGR_SM8475` 分支。
只有两处写死 liuqin：`thermal_level_requested` 的机型闸门（`xiaomi,liuqin`，或
`qcom,cape-mtp` + model "Liuqin based on …"，`d927fe0e0532`）和 0336 里的一条错误信息。

**diting 上要改什么才能试：**

1. `pmic-glink` 节点的 compatible 改成 `"qcom,sm8475-pmic-glink", "qcom,sm8450-pmic-glink", "qcom,pmic-glink"`。
   我们现在是 `"qcom,sm8450-pmic-glink", "qcom,pmic-glink"`
   （`sm8475-xiaomi-diting.dts:1473`），所以驱动走的是 SM8350 的布局，另加我们自己的三个补丁
   （0025 属性编号、0091 电流符号、0093 通知 0x50），它们与 0236 的同一段重叠，要合并。
2. 连接器 NTC 是可选的。diting 的原厂覆盖层声明了与 liuqin 相同的通道：`channel@347`，
   ratiometric，`hw-settle-time 200`，pre-scaling 1:1。要加 ADC7 节点下的 `channel@347` 和
   pmic-glink 节点上的 `io-channels` / `io-channel-names = "connector-temp"`。
3. 热敏电阻只是描述性的。diting 原厂的通道是 0x144 `pm8350_msm_therm`、0x145
   `pm8350_flash_therm`、0x146 `pm8350_hot_pocket_therm`、0x34d `pm8350_charger0_therm`、
   0x44a / 0x44b `pa_therm`、0x44c `wifi_therm`，标签和 liuqin 的对不上（0x144 在 liuqin 叫
   skin）。
4. `thermal_level_requested` 的闸门保持关闭。

**必须自己重新推导的：XM 属性编号。** 0341 的 45 / 46 / 44 / 139 和刷新用的 86 是从 liuqin 的
原厂模块 `qti_battery_charger_main_m81.ko`（sha256 `b13b976e…`）推出来的。diting 的原厂模块是
另一个二进制（sha256 `8ef574fc…`，从手机的 `vendor_boot_b` 取出），属性名相同
（`verify_digest`、`verify_slave_flag`、`request_vdm_cmd`、`pd_verifed`、`apdo_max`、
`power_max`、`bq2597x_*`、`connector_temp`、`soc_decimal`），但编号从字符串里读不出来。
在信任这些编号之前，得先从 diting 自己的模块里推。**电池固件的属性编号同理**：7.2.10 的上游
驱动已经带 `state_of_health` 和 `internal_resistance`，枚举和 6.17 不同，`sm8475_bat_props`
不能照抄。

**用户态：`liuqin-mipps-auth`**（980 行 Python，`mainline/device/gnome-overlay/usr/local/libexec/`）。
它找 `/sys/devices/platform/pmic-glink/*/xiaomi`，序列是：

1. 电量计认证：对主、副电量计各写 `verify_slave_flag`，写 32 字节随机挑战到 `verify_digest`，
   等 1.4 s，用 `HMAC-SHA256(挑战, FG_KEYS[i])` 核对回读；写 `authentic` / `slave_authentic`。
2. 等 PD 合同：`real_type` 是 `PD` / `PD_PPS`，`current_state` 是 `SNK_Ready`，PPS 时 `pdo2`
   非零。
3. 对端 SVID 是 `0x2717`（小米）时先把 `data_role` 切到 `host`。
4. 发 UVDM 命令 1、2、3，再 4（会话种子），再 5（16 字节随机挑战）；从 `request_vdm_cmd`
   读 state 5 的应答，用 `HMAC-SHA256(KEYS[i], 挑战 + adapter_id)` 的前 32 个十六进制位核对。
5. 按原厂顺序发命令 7（`REMOVE_COMPENSATION`）再 6（`VERIFIED`）。
6. 写 `pd_verifed`。认证通过是 1；`--allow-unverified-adapter` 下只要是就绪的 PPS 合同也写 1。

密钥是脚本里的字面量（`SEEDS` 10 × 128 位，`KEYS` 10 × 256 位，`FG_KEYS` 2 × 256 位）。许可：
`NOTICE` 写明它衍生自 ianchb 的 `xiaomi-mipps-auth`，**GPL-2.0-only**，不在项目的 MIT 之内。

**对 diting 的风险（评估）：**

- diting 只有一个电量计（`L12_5000mah`），对方是两个；守护进程把副电量计验证设成必需，失败
  就退出，必须改。
- 120 W 充电器与 67 W 的读数范围和单位可能不同；“先 7 后 6”的顺序只在原装 67 W 上验证过；
  标准的 PPS 放行会对任何就绪的 PPS 源写 `pd_verifed=1`，等于告诉固件打开高压通路。
- `0343` 意味着接墙充时永不挂起（SDP / CDP 除外）。对手机是否可接受是产品决定。
- 连接器温度每秒发给固件一次；通道或比例错了，固件会按假温度动作。
- 带未验证语义的写操作：`BATT_CHG_CTRL_LIM`、`USB_INPUT_CURR_LIMIT`、每 10 秒的属性 86 读取、
  注入 75 °C 的 `connector_hot_test`。
- 0340 / 0341 的原版是 `wkai343/liuqin-linux-kit` 里的 linux-7.3 补丁（0037、0038），比 6.17
  的移植更接近我们的基线。

**关机充电**：只能由引导程序进入——initramfs 检查 `/proc/cmdline` 里的
`androidboot.mode=charger`。仓库里没有任何代码主动进入这个模式。组件在
`mainline/device/charger-mode/`：一个不挂载根分区的 shell 循环（采样电量、记日志到 kmsg 和
pmsg）、复用 MiPPS 认证的 `liuqin-charger-auth`、用 DRM dumb buffer 在 DSI 面板上画图的
`liuqin-charger-screen`（GPL-2.0-only）、NCM gadget 加 busybox httpd、电源键分类（短按开机、
长按 2 秒进 fastboot）。运行时需要 initramfs 里有 Python 3、`libdrm.so.2`、liuqin 的背光名和
pstore pmsg。diting 的引导程序在关机插电时是否设置 `androidboot.mode=charger` 未验证。

### 5.6 SLPI

`569f79be4a7d` 加 `module_param(slpi_auto_boot, bool, 0444)`，默认 true；
`a54c2b5501a7` 修正匹配字段。对方启动参数里带 `qcom_q6v5_pas.slpi_auto_boot=0`，由一次性的
`liuqin-slpi.service` 在传感器注册表可读之后才写 `start`，因为“有些机器上启动 SLPI 会把平板
重置”。我们的 SLPI 是开机自动起的，已有 0097 处理重复的 handover 中断。不需要移植，记作
排故时的一个开关。

### 5.7 TEE / QSEECOM

`0b5cd921fb52`（TEE 的 `close_context` 操作，6.18 的回移）、`e8f8cc13bcb7`（SCM 的 TA
加载 / 关闭 / listener 注册与应答）、`ea63b921c92c`（`qcom_mdt_read_image()` 把分段镜像拼成
一个 blob，支持 ELF64）、`6640846b3b6e`（`drivers/tee/qseecom/core.c`，`TEE_IMPL_ID_QSEECOM 5`）。
**不要按原样移植**：它们是 6.17 的形态，与 7.2.10 冲突。但它们提供的“用户态加载 TA +
listener”在 7.2.10 的上游代码里**没有**（上游只有内核内的 `app_get_id` / `app_send` 和一个
受白名单限制的平台设备），指纹要用就得另找更接近 7.x 的实现，见 FINGERPRINT.md。

### 5.8 iris

`a90359262dac`（Vishnu Reddy，`Fixes: bb8a95aa038e`，`Cc: stable`）把电源域关闭挪到时钟
关闭之后：

```c
 	dev_pm_genpd_set_hwmode(core->pmdomain_tbl->pd_devs[IRIS_HW_POWER_DOMAIN], false);
-	iris_disable_power_domains(core, core->pmdomain_tbl->pd_devs[IRIS_HW_POWER_DOMAIN]);
 	iris_disable_unprepare_clock(core, IRIS_HW_CLK);
+	iris_disable_power_domains(core, core->pmdomain_tbl->pd_devs[IRIS_HW_POWER_DOMAIN]);
```

带 `Cc: stable`，多半已经在 7.2.10 里；7.2.10 的 iris 电源代码搬到了 `iris_vpu3x.c` /
`iris_vpu4x.c`，我没有核对到对应位置。它与“用过 iris 后关机卡住”是否有关也未知。

对方在 `2cd5a6f8ef67` 里加的 SM8450 平台数据与我们 0078–0080 的差别：对方用
`iris_vpu3_ops`、复位 `bus` + `core`、继承 SM8550 的带宽和缓冲表、能力上限 8192×4320；OPP
240 / 338 / 366 / 444 MHz。我们用 `iris_vpu2_ops`、只复位 `bus`、SM8250 的带宽表、去掉
`PARTIAL_DATA` 缓冲。对方的 OPP 更低。我们的实现已验证逐帧精确，不需要换。

### 5.9 ASoC / LPASS

- `b8fd29b1f39a`（0327）：`q6dsp_clock_dev_probe()` 把 `dev_set_drvdata(dev, cc)` 挪到第一个
  时钟注册之前。提交说明：LPASS LPI pinctrl 经 `pm_clk` 恢复时，`clk_vote_q6dsp_block` 在
  clk prepare 锁下解引用空指针，挂死启动。
- LPASS macro / pinctrl 改 PM clock 的系列（`27f89a3ecb4c`、`5e8a6d0be27f`、
  `731b35e53f6a`、`2ebfc1448441`、`49ffc60e14de`）和保持时钟顺序的
  `cbfdce9aec69`（0303）：都是省电改造，上游那两个哈希没有进主线。
- TDM 系列（`5a666ded9078` … `dde5e417f9f6`）：上游提交的 6.17 形态回移，形状不对；
  我们有自己的 0047。
- `ecc36e1df9a9`（0306，采集图等到 TRIGGER 才离开 `PREPARED`）、`43ec60d3acfa`（0305，
  `g_apm` 加锁并在 `apm_remove()` 清掉）、`fedb35fd3a6a`（0294，wcd938x-sdw 没有本地
  regmap 时提前返回）：没有对应的 diting 症状。

### 5.10 蓝牙

`a58d5638fc55`（0296）上游 `5c4e9a8b1845` 已在 7.2.10 里。`e4a305e11437`（0307，FROMLIST
未合并）：`qca_power_shutdown()` 取消 IBS 工作、删两个 IBS 定时器、把 IBS 状态复位成 asleep。
它的触发条件是从用户态设置蓝牙地址；我们在设备树里给地址，不需要。

## 6. 采纳顺序建议

按项目流程（本地写补丁 → rsync → 远程 tmux 编译 → 手机实测 → 再提交）：

**第一批，各一个补丁、互不依赖：**

1. GMU 两个上游修复 `b9e43fbe6b23` + `cb8be68ec106`（直接取上游哈希 `2379434f8d3b`、
   `812aa5346482` 更干净）加手工移植的 `355dd22d6a31`。验收：重现 T45b 的场景（通话中、
   Waydroid 下、长时间空闲后），看是否还出现 OOB 超时，以及出现后能否恢复。
2. `960054da68da` + `a32e4e25f6c0`（上游 `8464e2284fec`、`eb34e2804ce4`）。验收：开机
   dmesg 不再有 `rcg didn't update its configuration`。
3. `594134933699`。验收：s2idle / deep 各几轮之后 `bluetoothctl show` 仍是 Powered，dmesg
   没有 `nobody cared`。
4. `5bbdbea6a307`。验收：多次冷启动， battmgr / 扬声器保护 / 声卡出现的时间稳定；DSP 重启
   和挂起正常。
5. 电量单位的最小移植：在我们的树上给 `CHARGE_COUNTER` 乘 1000（带溢出检查）、把
   `POWER_NOW` 和两个时间估计去掉。不引入整组。
6. `9bc411d03020`、`03b536ad4e2c`、`8ec7416f90f6`。

**第二批，需要人工移植和推导：**

7. 充电整组：先把 diting 原厂 `qti_battery_charger_main_m81.ko` 的属性编号推出来，再决定取
   哪些子集。最小的三个子集：电量单位（0236 的 battmgr 段 + 0342）、小米认证接口（0249 +
   0341）、连接器 NTC（0329、0330、0332、0335、0336、0337 整块）。
8. GPU 终止故障策略 `018982b5e1ac` + `fdf3c8b8b912`。
9. dts 的电压投票 `40d6ee58b96e`、CX 档位 `d54edba9153c`（要自己算 CX 列）、BWMON
   `309060c799a7`。

**第三批，等硬件前提确认：**

10. USB3：`ccee5e821158` + `10bddb4202c8` + 对方 dts 里的 `&usb_1_qmpphy` 段。
11. DP Alt Mode：只有确认 diting 的 Type-C 接了 SS 走线和 mux 才有意义。

## 7. 明确不建议移植的

- 上游 7.2.10 已有（§3 的 20 个）。
- liuqin 板级：`2cd5a6f8ef67` 的 dts 部分及其后续、NT36532 触控与笔、KTZ8866、S5KJN1 与
  camcc（我们有 0055–0057）、FPC1264 驱动 `b87eaebbd7b7` 与 FPC 接线 `7deb78827a94`、
  麦克风 dts。
- 硬件不支持：DP Alt Mode 整串、USB3 的 PHY 部分（待定）。
- 我们有已验证的等价实现：iris 平台数据（0077–0081）、fastrpc 冻结（0085）、CPU 容量
  （0105；`dynamic-power-coefficient` 与 DECISIONS D21 相悖）、OTG dts（0098）、TDM（0047）。
- 对方系列内部已被取代的：`42a085d01c31`（被 `cb62545d4f62` 撤销）、`c7d4d4ca507b` 和
  `7ec2c1f628c0` 的 debugfs 那一半（被 `95cf27cbc2e7` 删除）。
