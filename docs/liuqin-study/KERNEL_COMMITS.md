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

**更正（2026-11-26 晚）**：上午写的“带 `Cc: stable`，多半已经在 7.2.10 里”是错的——7.2.10 没有
这条，现已原样收为 0119。它管的是掉电时先关时钟、再关电源域的顺序。与“用过 iris 后关机卡住”
直接相关的是另一处：`iris_core_deinit()` 在 `core->lock` 里 `disable_irq()`，等中断线程退出，
而中断线程 `iris_hfi_isr_handler()` 也要拿这把锁。kit 的 0065 把排空中断这一步挪到锁外，收为
0121（见 §8）。

对方在 `2cd5a6f8ef67` 里加的 SM8450 平台数据与我们 0077–0080 的差别：对方用
`iris_vpu3_ops`、复位 `bus` + `core`、继承 SM8550 的带宽和缓冲表、能力上限 8192×4320；OPP
240 / 338 / 366 / 444 MHz。我们用 `iris_vpu2_ops`、只复位 `bus`、SM8250 的带宽表、去掉
`PARTIAL_DATA` 缓冲。对方的 OPP 更低。（更正）解码确实够用，编码不够。Iris2 的掉电序列——
每条 pipe 的 NoC 空闲、NoC 复位、两个 AHB 桥复位，然后才塌缩 MVS0——在 7.2.10 里只有
`iris_vpu3_ops` 那条路做，原厂 Waipio 驱动的 `__power_off_iris2_hardware()` 就是这个顺序；复位
也确实是 `bus` + `core` 两个。0123、0124 按对方和原厂的做法改了这两处，并换成原厂的帧上限和
负载上限（`MAX_MBPF` 276480、`MAX_MBPS` 7833600）。没动的：时钟公式保留 VPU 2.0 的——对方的
公式去掉了编解码系数（CABAC ×1.35、VP9 ×1.70），像素开销还除以 pipe 数，4K60 算出 114 MHz，
原厂公式对 CABAC 流是 191 MHz、VP9 是 296 MHz——以及带宽表和 OPP 表。

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
- 我们有已验证的等价实现：iris 平台数据（0077–0081；**解码部分**是等价的，掉电序列、复位和上限
  已在 0123、0124 里按对方的做法改了，见 §5.8 和 §8）、fastrpc 冻结（0085）、CPU 容量
  （0105；`dynamic-power-coefficient` 与 DECISIONS D21 相悖）、OTG dts（0098）、TDM（0047）。
- 对方系列内部已被取代的：`42a085d01c31`（被 `cb62545d4f62` 撤销）、`c7d4d4ca507b` 和
  `7ec2c1f628c0` 的 debugfs 那一半（被 `95cf27cbc2e7` 删除）。

## 8. 采纳记录（driver-fix 分支）

第一批按 §6 的顺序做成了补丁，放在 `kernel/patches/0106`–`0115`（后九个来自 §6，0115 是
核对时带上的，见下）。**0106–0114 和收尾的 0116–0118 都是在 2026-11-26 换上之后、手机实测过才
提交**；0115 更早，单独提交（`c25c95e`）。

| 补丁 | 来源 | 内容 | 状态 |
| --- | --- | --- | --- |
| 0106 | 上游 stable `812aa5346482`（原样） | HFI 中断只清 CM3 fault 位 | DEVICE-TESTED（启动正常；它针对的挂死场景没有触发） |
| 0107 | 上游 stable `2379434f8d3b`（原样） | 启动 GMU 前屏蔽 HFI 中断 | DEVICE-TESTED（同上） |
| 0108 | 上游 `8464e2284fec`（原样） | `disp_cc_mdss_mdp_clk_src` 的 ops | **DEVICE-TESTED**：开机的 `rcg didn't update` 和 `clk_rcg2_shared_disable` 警告栈都没了 |
| 0109 | 上游 `eb34e2804ce4`（原样） | Lucid Ole PLL 已使能时跳过配置 | DEVICE-TESTED（启动、显示正常；它防的花屏不会按需出现） |
| 0110 | liuqin `594134933699`（原样） | GENI 串口挂起期间屏蔽中断 | DEVICE-TESTED（启动正常；挂起没法测，见下） |
| 0111 | liuqin `355dd22d6a31`（移植：只是落点不同，7.2 的冷/热启动判定多了 a8xx 分支） | 挂死恢复时强制冷启动 | DEVICE-TESTED（启动正常；恢复路径没有触发） |
| 0112 | liuqin `5bbdbea6a307`（移植：只有最后一个 hunk 的上下文不同） | glink 暂存端点就绪前的消息 | DEVICE-TESTED（启动：ADSP/CDSP/SLPI 服务都在；挂起没法测） |
| 0113 | liuqin `787d0f7bf966`（改写：挂在我们自己的 `bat_prop_constant_current` 标志上，属性仍列出但返回 `-ENODATA`） | 电量计数 mAh → µAh，去掉占位的 `power_now` 和时间估计 | **DEVICE-TESTED**（热加载，和整机启动，见下） |
| 0114 | 上游 stable `04854437df76`（移植：只有后面的上下文不同） | 电源设备不注册为唤醒源 | **DEVICE-TESTED**（热加载，和整机启动，见下） |
| 0115 | **不是来自 liuqin**：本仓库 `encoder` 分支的 `0111-…-iris-Raise-MXC-…`，原样 | iris 在 366 / 444 MHz 两档把 MXC 提到下游要求的档位 | 手机上自 2026-11-23 起一直带着；这批编出的 DTB 与 r54 的相同 |
| 0116 | liuqin `9bc411d03020`（原样；它标注的上游哈希不存在，是对方自己的） | DSI：`pm_runtime_get_sync` 改 `pm_runtime_resume_and_get`，时钟失败向上传 | DEVICE-TESTED（见“收尾的三个”） |
| 0117 | liuqin `8ec7416f90f6`（原样） | DPU：运行时恢复、使能时钟之前，把核心时钟的 OPP 投票补回来 | DEVICE-TESTED（熄屏/亮屏多次，机主确认） |
| 0118 | liuqin `03b536ad4e2c`（原样；Sam Day） | `msm_gem_submits` 改 `kvzalloc`，上限 `KMALLOC_MAX_SIZE` | DEVICE-TESTED（图形会话照常渲染） |

“原样”是相对我们“v7.2.10 + 0001–0105”的树说的：零模糊度直接套上，`git am` 不需要模糊
匹配。两个“移植”的代码与原补丁相同，只是重新生成了上下文。作者和提交说明都保留原作者的，
末尾加一段 `Origin:` 说明出处和移植时改了什么。

**编译**（内核容器，见 `ubuntu-diting/ci/KERNEL.md`）：先从零编了一遍不带新补丁的基线
（14 分钟，日志里 0 条 warning），再加上这九个补丁增量编译：正好重编 6 个源文件，0 条
warning；`linux-image` 包与基线相比只有 6 个文件不同——内核镜像、`System.map`、`msm.ko`
（a6xx_gmu）、`dispcc-sm8450.ko`、`qcom_battmgr.ko`，外加 changelog 的时间戳。

**0115 是核对时发现的**：把容器编出的 DTB 与手机上现刷的 r54 DTB 对比，只有一处不同——
iris（视频编解码器）OPP 表里 366 和 444 MHz 两档的 `required-opps`。手机上的 MXC 是
SVS_L1 和 NOMINAL，仓库里的 0079 是 SVS 和 SVS_L1。追下去是 `encoder` 分支的提交
`7731dea`（"iris OPP table - raise MXC to the downstream corner"）：下游驱动要求这两档
在 MXC 和 MMCX 上都是 SVS_L1 和 NOMINAL，仓库原来的表让视频核心在最高的两档工作在
规格之外，“解码碰巧没事，编码一起动就让整个 SoC 复位”。这个修复只在 `encoder` 分支上，
`main` 没有。它不属于 liuqin 的审计，但 `driver-fix` 要从 `main` 出发构建，不带它的话
测出来的内核在视频这一项会比手机上现跑的倒退，所以原样放进这一批。带上之后 DTB 与
r54 的那个逐字节相同（见 `release/driver-fix-batch1/README.md`）。0115 已经单独提交：
它就是手机上从 2026-11-23 起一直在跑的设备树，不需要再等。

**没有核实的两点**：下游驱动对这两档的要求，出自 `encoder` 分支那次调查的测量，原厂
内核源码在旧构建主机上、随重装丢了，这里没法再对一遍；解码实际会不会用到 366 和 444
MHz 也没有量到——量它的尝试（12 路并发解码）把固件压到了看门狗，驱动在错误处理路径上
死锁，见 `ubuntu-diting/docs/KNOWN_ISSUES.md`。（2026-11-26 晚更正其中一点：原厂视频驱动的
源码本地有副本，`video-study/moto-video/driver/`，0123 的掉电序列是对着它核过的；0115 那两档
的 MXC 要求这回没有去对。）

**手机上的验证（不改 boot 分区）**：`qcom_battmgr` 是模块，内核配置又与手机上运行的内核
逐字节相同，所以把新编的 `qcom_battmgr.ko` 放进 `/lib/modules/7.2.10-diting/updates/`，
`depmod -a` 后卸载重载（项目以前测 0091、0093 用过同样的办法）。同一个内核、同一块电池：

| | 手机自带的模块 | 带补丁的模块 |
| --- | --- | --- |
| `charge_counter`（满电） | 4103 | **4103000** |
| `power_now`（电流为 0 时） | 10000000 | 无数据 |
| `time_to_full_avg` / `time_to_empty_avg` | 0 / 65535 | 无数据 |
| 三个电源设备的 `power/wakeup*` 属性 | 各 9 个 | **0 个** |
| upower | 按 10 W 上报 | `energy-rate: 0 W`，日志无错误 |

USB 电源照常 `online=1`。测完已删掉 `updates/` 里的文件并重载回原模块，手机恢复原状。

**换上内核镜像之后的实测（2026-11-26）**：机主让代理直接刷。按机主的做法，交付物是
`boot.img` 和 `vendor_boot.img`，不装 deb：在内核容器里用项目自带的 `diting-mkbootimg`
生成两个镜像——本批的内核 Image、本批的 DTB、从现刷的 `vendor_boot_a` 里取出的
initramfs、`diting.conf` 的命令行。两处交叉校验都对上了：`boot.img` 与“formal-52 的
`boot.img` 从第 4096 字节起换成新内核”逐字节相同，`vendor_boot.img` 与 r54 的逐字节
相同。所以只写了 `boot_a`，`vendor_boot_a` 没动。三个模块（`msm.ko`、
`dispcc-sm8450.ko`、`qcom_battmgr.ko`）放进 `/lib/modules/7.2.10-diting/updates/` 再
`depmod -a`：镜像里不带模块，不放进去这三处修复就不生效；其余 1716 个模块与手机上的
代码相同（只差 20 字节的构建 ID），所需符号新内核全部导出。写之前把 `boot_a`、
`vendor_boot_a` 完整备份到 `device-data/images/20261126-pre-driver-fix/`，并与手机核对过。
镜像怎么生成、怎么刷、怎么回退，见 `release/driver-fix-batch1/README.md`。

同一个手机，换之前和换之后：

| 读数 | 之前 | 这批 |
| --- | --- | --- |
| `/proc/kallsyms` 里的 `qcom_glink_deliver_pending` | 0 | **1** |
| 开机的 `rcg didn't update its configuration` | 每次开机 1 条 | **0** |
| 开机时 `clk_rcg2_shared_disable` 的 WARNING 栈（udev 加载 dispcc） | 有 | **没有了** |
| 开机头 180 秒的日志，warning 及以上的行数 | 3631 | **300** |
| 启动失败的单元 | 18 个 | 1 个（`calls-daemon`，以前也失败）；第二次开机 0 |
| `charge_counter` | 4097 | **4097000** |
| `power_now` / `time_to_*_avg` | 10000000 / 0、65535 | 无数据 |
| 三个 `qcom-battmgr` 电源设备的 `power/wakeup*` 属性 | 各 9 个 | **0 个** |
| 开机后的系统状态 | degraded | **running** |
| D 状态进程 | 10（那次开机的 iris 死锁） | **0** |

蓝牙、Wi-Fi、面板、声卡、GPU、四个 remoteproc（调制解调器注册并连上）、12 个 `diting-*`
服务都在。内核日志里没有新增的警告；原有的照旧（0.8 秒处的 10 条 SMMU context fault——那只是
限速后留下的 10 条，实际至少 3232 条，来自显示控制器，见 KNOWN_ISSUES；CPU feature
variation、dummy regulator、4 条 wcd938x）。

**没有验证到的**：0106、0107、0111 针对 GPU 挂死，没有去触发；0109 防的花屏不会按需
出现；0110 和 0112 的挂起场景没法测——日志里 50 次开机没有一次挂起。§6 第一批里“挂起后
蓝牙是否还在”因此仍然待测，0114 对挂起的影响也一样。

**视频解码只做了一次回归检查，然后按机主的决定搁置**：`VIDEO_DECODE.md` 里 GStreamer
V4L2 对软解的逐帧比较，结果与旧内核上记录的相同。但开机后最先的几次解码，硬件输出与
软解不一致，解码器用过一阵之后同一批片子又逐字节一致；为了不重启就复现，我手动卸载再
加载了 `qcom_iris` 并立即解码，**手机当场复位**（日志戛然而止，pstore 为空），原因没有
查。已记入 `ubuntu-diting/docs/KNOWN_ISSUES.md`。搁置的含义：其它驱动都正常之前，不做
解码实验，也不卸载重载 `qcom_iris`。（2026-11-26 晚：机主决定开始全面修复 iris 编码，为此
做的解码回归和一次并发压力测试见下面“第二批”；不卸载重载 `qcom_iris` 这一条不变。）

**收尾的三个（0116–0118，§6 第一批第 6 项）**：都只改 DRM 代码，编译后内核镜像、
`System.map`、DTB 与第一批逐字节相同，变的只有 `msm.ko`。所以没有再生成立镜像：把新的
`msm.ko` 换进 `/lib/modules/7.2.10-diting/updates/`（第一批的那份留在手机
`/var/tmp/msm-batch1.ko`，也在 `release/driver-fix-batch1/modules/`），重启一次。

- 0117 改的是 DPU 运行时恢复。这条路径在这台设备上每次亮屏都会走：显示控制器有 OPP 表
  （`mdp_opp_table`，172–500 MHz 五档），熄屏后它确实进入运行时挂起。实测带着新模块开机
  785 秒内累计挂起 464 秒、运行 321 秒，中间多次熄屏、亮屏（登录界面的空闲熄屏，和机主
  登录后的正常使用），内核日志里 `failed to vote for core clock rate` 0 条、`[dpu error]`
  0 条、DSI 报错 0 条；**机主确认“能正常开关屏幕”**。开机后内核日志 warning 及以上
  82 行，换之前是 87 行，没有新增的。
- 这棵树的 `dev_pm_opp_set_rate()` 先对目标频率做 `clk_round_rate` 再向上取 OPP，不要求
  精确相等，所以 0117 用当前时钟频率去投票不会误报失败（换之前先在源码里确认过）。
- 0116 动的是 DSI 的错误分支，0118 是提交对象的分配方式：正常路径里都看不出来，能验证
  的只是“没坏”——开机、面板点亮、图形会话渲染都照常。它们防的情形（时钟失败、严重内存
  碎片）没有去触发。
- 挂起路径只在 2026-11-26 手动试了一次（手机平时不自动挂起，这是设计，见
  `ubuntu-diting/docs/ALWAYS-ONLINE.md`）：接 USB 充电时深度挂起，闹钟定的 60 秒，25.05 秒
  后被别的事件唤醒，唤醒源没有追。所以 0114 之外还有唤醒来源，0110/0112 的挂起场景仍然
  没有验证。
- 用 `wlr-randr --output DSI-1 --off` 去模拟熄屏是错的：内核里面板并不会关，合成器还会
  留下一条 `[dpu error] invalid parameters`（旧的 `msm.ko` 上就有，是我们自己的操作造成的，
  日志里别当成驱动问题）。要测这条路径，等合成器自己熄屏（`idle-delay`），再用同一用户的
  `wlr-randr --output DSI-1 --on` 唤醒。

### 第二批：iris 编码器（0119–0129，2026-11-26）

机主看过 liuqin-linux-kit 之后决定以它为蓝本全面修复编码。kit（`wkai343/liuqin-linux-kit`，
HEAD `0a91067`，2026-11-25，169 个提交）是 Linux 7.3.4 加 80 个补丁，在同一个 SoC 上把
H.264 / HEVC 编码做通了。上面第一节对照的是 liuqin 的主线内核仓库，“iris 平台数据没有值得换的”
只对解码成立。

编码不工作的原因（kit 的 0068–0070，加上前后的 0065、0066、0096）：Iris2 上编码器的 ARP 缓冲
必须分配在安全的非像素 DMA 上下文里——SID `0x2184`、VMID 11（`CP_NON_PIXEL`）、IOVA
`0x01000000`–`0x257fffff`——并通过 `qcom_scm_assign_mem` 把这一上下文的 SMMU 页表共享给
VMID 11；核心的复位和掉电要按原厂驱动的顺序来。diting 的设备树和固件（`vpu20_4v.mbn`）本来就
带着这个安全上下文，**所以不用升到 7.3.4**。

| 补丁 | 来源 | 内容 | 状态 |
| --- | --- | --- | --- |
| 0119 | 上游 `9cfae7726a9a`（原样；即 §5.8 的 `a90359262dac`） | 掉电时先关时钟，再关电源域 | DEVICE-TESTED |
| 0120 | 上游 `cc330f558996`（原样） | 进入 HW 模式之前复位 AHB 桥 | DEVICE-TESTED |
| 0121 | kit 0065（原样，只有三处上下文不同；它本身改编自上游待合并的 safe-power-off 系列） | 掉电前在 `core->lock` 之外把中断排空 | **DEVICE-TESTED**：固件报系统错误之后，错误处理线程跑完、核心回到 suspended、没有 D 状态进程。旧内核在同一条路径上死锁 |
| 0122 | kit 0066 | 固件交回的空捕获缓冲不交给用户态，直接回收 | DEVICE-TESTED：解码回归与软解一致 |
| 0123 | 本地（序列对照原厂 `msm_vidc_iris2.c` / `msm_vidc_waipio.c`；上限取 kit 的 SM8450 平台数据） | SM8450 改用 VPU3 的掉电序列；原厂的帧上限、负载上限和周期开销；时钟公式不变 | DEVICE-TESTED |
| 0124 | 本地（按原厂设备树） | 视频核 wrapper 的 `bus`、`core` 两个复位；绑定文档里各 SoC 各写各的复位名 | DEVICE-TESTED |
| 0125 | kit 0068 | arm-smmu-qcom：把 SID `0x2184` 上下文的页表共享给 `CP_NON_PIXEL` | DEVICE-TESTED：开机时建出安全上下文（iommu group 16），编码可用，解码回归不变 |
| 0126 | kit 0069 | 设备树：描述 Iris 的安全非像素上下文 | DEVICE-TESTED（同上） |
| 0127 | kit 0070（移植：改到 7.2 的 SM8450 平台数据上，三个平台标志顶替 0081 的 `no_encoder`） | 启用编码器：ARP 在 `CP_NON_PIXEL` 里逐会话分配；按原厂的重构缓冲布局；接受 Iris2 的 DRAIN 应答 | **DEVICE-TESTED**：H.264 / HEVC，720p30 到 4K30 |
| 0128 | kit 0096 | SM8450 的 H.264 电平按捕获缓冲大小限制 | DEVICE-TESTED：4K 流的 SPS 电平 5.1 |
| 0129 | 上游 `a6ee1766b3db`（手工移植） | 编码器的 CBR 码控强制 stage 1 工作模式 | DEVICE-TESTED：CBR 300 帧，平均 4260 kbit/s（要的是 4000） |

**编译**：0 条 warning。`config` 与上一批逐字节相同，新旧模块树只有 `qcom-iris.ko` 不同，所以
只把它放进 `/lib/modules/7.2.10-diting/updates/`；`System.map` 多了 3 个 SMMU 函数；DTB 变了
（0124 的复位线），所以这一批 `boot_a` 和 `vendor_boot_a` 都要写。两个镜像的核对：`boot.img`
与上一批的 `boot.img` 从第 4096 字节起换成新内核逐字节相同；`vendor_boot.img` 与手机上刷着的
那份只差 DTB（DTB 之外只有头部里 dtb 长度那 1 个字节）。写之前两份分区备份在
`device-data/images/20261126-pre-batch4-iris/`，与手机核对过。镜像怎么生成、怎么刷、怎么回退，见
`release/driver-fix-batch4-iris-encoder/README.md`。

**手机上读到的**（2026-11-26 18:18 启动，日志在 `release/driver-fix-batch4-iris-encoder/logs/`）：

| 项目 | 结果 |
| --- | --- |
| 解码，ffmpeg 三条路径 | H.264 1080p / 4K、HEVC 1080p、VP9 1080p（Profile 0）：VA-API 与 `*_v4l2m2m` 都与软解同摘要，与刷之前的读数相同。10-bit 的两处老问题不变（VA-API 画面错，m2m 不支持 P010 采集） |
| 解码，GStreamer 对软解 | H.264、HEVC 8/10-bit、VP9 Profile 0 / 2 的 1080p 流各 90/90。VP9 两条以前是“89 帧全部不一致”，多半是 0122 的效果；带隐藏 alt-ref 帧的 320×240 探针流仍然 108 帧、0/90 |
| 编码，平均 PSNR 对源 | H.264 / HEVC：720p30 60 帧 45.5 / 46.0 dB；1080p30 60 帧 45.3 / 46.5 dB；1080p60 120 帧 41.7 dB；4K30 60 帧 39.3 / 39.7 dB。送进去的帧数与流里解出来的一样 |
| 编码，其它 | 两个编码器同时各 1800 帧（45.5 / 45.5 dB）；边硬解边编码，解码摘要不变；CBR 300 帧 44.7 dB |
| 内核日志 | 从开机到压力测试之前共 1085 秒，warning 及以上一直是 88 行，没有新增 |
| 12 路 4K 解码同时开 | 驱动放行 8 路、拒 4 路（0123 的上限），固件对那 8 路报致命系统错误（`0x5000003`）。没有死锁，之后解码和编码照常。细节和遗留问题见 KNOWN_ISSUES |

**没验证到的、没做的**：

- 看门狗那条路径本身没有再走到（固件这次报的是致命错误，不是看门狗），所以“看门狗不再死锁”
  没有证明；证明的是“固件报系统错误之后驱动不再锁死”。
- 过度订阅的错误路径还有四处毛刺：`vb2_start_streaming` 的 WARNING（上游 7.3.4 也一样）、一次
  SMMU 页错误、ffmpeg 在解码出错后用户态空转、驱动的准入上限高于固件的实际能力——0123 采用的
  上限放行 8 路 4K，固件在这个负载下出错。`iris_check_core_mbps()` 可以按每秒宏块数限制负载，
  但准入检查没有调用它。
- 原版 ffmpeg 在帧高度不是 32 的倍数时随机崩溃（按补齐后的高度去拷贝，读越过源帧末尾）；把
  输入补齐到 32 的倍数后稳定通过。kit 的 7 个 FFmpeg 补丁没有移植，这是用户态的下一步。
- 强制关键帧：驱动没有这个控制（上游 7.3 才有）。HEVC 在 4K 的电平没有约束。
- 换上之后没有专门测过关机还会不会卡在 `systemd-shutdown`。
- kit 里剩下的补丁只做了初步分类，没有逐个核对，也没有移植：Type-C / UCSI（0022、0040–0045、
  0072、0073、0076）、M81 充电与电池（0038、0043、0055、0078、0079）、音频（0047–0058）、
  摄像头（0086、0093）、GPU（0061 的 OPP 依赖、0081 的 GMU 故障转储等待、0082 的恢复失败后
  停止提交）、liuqin 板级的 CPU 容量与冷却映射（0035、0036、0077）。

第二批（充电整组、GPU 终止故障策略、dts 的电压投票）和第三批（USB3 / DP）没有动，下一
批从充电整组开始。

### 第三批：会话准入、错误路径、恢复路径上的洞（0130–0135，2026-11-26）

| 编号 | 来源 | 内容 |
| --- | --- | --- |
| 0130 | 上游 `397ebadcbc` | 会话数到上限时拒绝 `open()`（`-EBUSY`） |
| 0131 | 本地，跟着 0130 | 被拒绝的实例释放它的控制句柄（0130 的失败路径漏了这一步） |
| 0132 | 上游 `4524809316` | 驱动卸载时取消系统错误处理的工作 |
| 0133 | 本地 | 出错实例的缓冲按“已排队”交还；会话先取走缓冲再放进就绪队列。两个 videobuf2 警告消失 |
| 0134 | 本地，按固件实测 | SM8450 的准入上限改成 130560 宏块/帧（4 路 4K）；原来是厂商的 MAX_MBPF（8 路 4K） |
| 0135 | 本地 | `iris_core_init()` 在 `IRIS_CORE_ERROR` 时不再把状态写成 `IRIS_CORE_DEINIT`——那会让恢复线程跳过断电，把还开着的核心再上电 |

**手机上读到的**（模块 `13c30150b3afe8f5…`，2026-11-26 23:05 起；内核镜像、配置、DTB 与第二批
逐字节相同，只换了 `updates/qcom-iris.ko`。日志在 `release/driver-fix-batch5/logs/`）：

| 项目 | 结果 |
| --- | --- |
| 准入 | 5 路 4K 解码同时开：第 5 路被拒（`current session not supported(-12)`，ffmpeg 对它回落软解），其余 4 路解到头。改之前，第 5 路及更多在 9 次里全部以固件的致命系统错误收场 |
| 会话上限 | 一个进程开 20 次解码节点：16 次成功，第 17 次起 `EBUSY`；过载之后照旧 |
| 错误路径 | 15 路 1080p 同时开、以固件错误收场的那几次：videobuf2 警告 0 条，进程 2–6 秒内自行退出，没有 D 状态，之后解码摘要不变 |
| 恢复路径的洞 | 每 2 毫秒一次 open/close 配合同样的过载，三轮：每轮有 53–75 次 open 落进“已报错、尚未重建”的窗口被拒，`Unbalanced enable` 0 条、看门狗 0 条、没有复位，每轮之后解码正确 |
| 解码 | ffmpeg 三条路径与 GStreamer 的摘要都与之前相同 |
| 编码 | 静态 ffmpeg 9.1（带 kit 的 7 个补丁）各档帧数全对；手机自带的 ffmpeg 偶发丢尾帧（用户态的问题，见 KNOWN_ISSUES） |

**事故**：这一批的第一版还把出错实例的队列标记为错误（`iris_inst_change_state()` 里调
`vb2_queue_error()`）。用它时手机复位了两次（21:33，以及七分钟后带实时日志的重放）。根因不是
标记，是上游 `iris_core_init()` 的那个洞（0135）：固件报错之后、恢复线程运行之前，一次 `open()`
被拒绝，顺带把核心状态写成了 `IRIS_CORE_DEINIT`，而核心还开着；恢复线程因此跳过断电，再上电时
报 `Unbalanced enable for IRQ 219`（就在那条 `core init failed` 之后 9.6 毫秒），2 秒后看门狗，
再开会话即复位。标记只是让 `open()` 更容易落进那个窗口。过程中先把手机退回第二批的模块，再去掉
标记重做（22:04），最后读代码对日志找到这个洞，补上 0135（23:05）。去掉标记的那一版本身带着
这个洞：同样的序列跑了三次没碰到窗口，带标记的两次都碰到了。

**没解决、没验证的**：

- 15–17 路 1080p 仍然时而过载出错（固件的致命错误）：同时起的 16 路 2 次全败，15 路 4 次败 3 次，
  间隔 0.5 秒起的 17 路 6 次败 3 次；13、14 路和间隔 1 秒起的 16 路都过。按帧大小的上限分不开这些。
- 每次固件错误伴随一条视频核心的 SMMU 上下文错误（`SID=0x2184`）；恢复线程在出错会话退出前约每秒
  重建一次（4 秒里最多 11 条 `received system error`）。
- 0132 没有验证（这台手机上不卸载模块）。
- 强制关键帧：驱动没有这个控制（上游 7.3 才有）。HEVC 在 4K 的电平没有约束。

**用户态**：kit 的 7 个 FFmpeg 补丁迁到了 n9.1（`ubuntu-diting/packages/ffmpeg-diting`，
`git am -3` 无冲突），手机上在 docker 镜像里编出静态二进制，验收七项全过
（`ubuntu-diting/ci/FFMPEG.md`）。并入 rootfs 的方式（机主 2026-11-27 定）：二进制装进镜像的
`/usr/local/bin/`，动态链接 Ubuntu 26.04 的库，不动归档的 ffmpeg；常见的外部库（https、libx264 等）都要，
硬件只留 V4L2 这几路。
