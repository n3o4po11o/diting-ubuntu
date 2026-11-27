# 视频硬件编码进浏览器：在 V4L2 编码器上做 VA-API（Chromium）

状态：**第 1–11 节是 2026-11-27 的评估，原样保留；实施记录在第 12 节**，读的时候以它为准
（它更正了评估里的几处）。“现状”是那天在手机上（内核 `7.2.10-diting`，固件
`vpu20_4v.mbn`，Chromium snap `158.0.8127.36`）、在源码里（Chromium 分支 `8127`、
`radxa-pkg/qcom-va-driver@ee8622c`、我们的内核树）读出来的；没有读过、没有试过的地方标了
“待核实”。

目录：[0 结论](#0-结论) · [1 现状](#1-现状已核实) ·
[2 Chromium 的用法](#2-chromium-在-linux-上怎么用-va-api-编码) ·
[3 参考实现](#3-参考实现qcom-va-driver) · [4 逐项对照](#4-逐项对照) ·
[5 方案](#5-方案比较与推荐) · [6 要做的改动](#6-要做的改动) ·
[7 估时](#7-工作分解与估时) · [8 测试计划](#8-测试计划) ·
[9 风险与限制](#9-风险与限制) · [10 待核实](#10-待核实) · [11 出处](#11-出处) ·
[**12 实施记录**](#12-实施记录2026-11-27)

## 0 结论

1. **能做，而且不用从零写。** `qcom-va-driver`（Radxa 维护，MIT 许可）已经在高通 Iris 的
   V4L2 stateful 编码器上实现了 VA-API 编码：H.264（Constrained Baseline、Main、High）和
   HEVC Main，CQP/CBR/VBR，128×128 到 4K。它的目标芯片 SC8280XP 和我们这颗用的是同一代
   固件接口（HFI Gen2）。但它只测过 FFmpeg、GStreamer、Sunshine，**没测过 Chromium**，也没在
   SM8475 的固件上跑过。
2. **Chromium 这侧是通的。** Linux 版有完整的 VA-API 编码路径（`VaapiVideoEncodeAccelerator`，
   手机上这个构建里就有），只是被 feature `AcceleratedVideoEncoder` 挡着，默认关闭。它接受
   “SPS/PPS/条带头由驱动生成”的驱动，参考驱动正是这么做的。
3. **三个缺口。**
   - 内核没有强制关键帧控件 `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`。上游 7.3 有，回移 gen2 部分
     约 43 行。
   - 参考驱动的编码器不允许在会话中改码率、帧率、QP 范围。视频通话每一两秒就改一次码率，这
     条不补就只能用于 WebCodecs 这类“配置一次”的场景。
   - 换驱动意味着解码也一起换（一个 DRM 设备只能挂一个 VA 驱动）。现有的浏览器硬解是花了几
     天稳定下来的，换过去要重新验证。
4. **硬件够用。** ffmpeg 直接走 V4L2：720p 约 650 帧/秒，1080p 约 340，4K 约 70（都含 CPU 上
   传）。固件自己做 16 像素对齐并写帧裁剪，小尺寸和奇数尺寸也能编。VBR 要 4 Mbit/s 实测
   4.3–4.5。
5. **建议的路线。** 先做一轮**不动内核**的验证：参考驱动原样编译，Chromium 打开开关，看
   WebCodecs 能不能真的用上编码器。然后补内核的关键帧控件和驱动的运行时参数更新。最后用现
   有解码回归脚本决定解码侧怎么走：通过就整体换驱动（方案 A），不通过就只移植它的编码器
   （方案 B）。
6. **估时**（粗略，见第 7 节）：方案 A 约 9–16 人日，方案 B 约 12–22 人日。
7. **不在范围内。** HEVC（Chromium 的 Linux 版没有 HEVC 编码路径）、B 帧（固件能出，但
   Chromium 的 VA 路径和参考驱动都按无 B 帧工作）、多时间层（参考驱动不支持，Chromium 两条
   以上时间层还需要打包原始数据）、空间分层和 simulcast（Chromium 的 VA 编码器本身不支持）。

## 1 现状（已核实）

### 1.1 硬件、内核、固件

| 项 | 值 |
| --- | --- |
| 视频核 | Iris2（VPU 2.0 核 + Gen2 HFI），固件 `qcom/sm8475/xiaomi/diting/vpu20_4v.mbn` |
| 内核 | `7.2.10-diting`，`CONFIG_VIDEO_QCOM_IRIS=m`；编码器自 0119–0129 起注册 |
| 编码器节点 | "Iris Encoder"，驱动名 `iris_driver`，V4L2 m2m 多平面。编号随开机变（这次是 `/dev/video7`），用 `v4l2-ctl --list-devices` 找 |
| 原始帧输入（OUTPUT 队列） | `NV12`、`Q08C`（UBWC） |
| 码流输出（CAPTURE 队列） | `H264`、`HEVC` |
| 码控 | `video_bitrate_mode` VBR（默认）/CBR；`video_bitrate` 和 `video_peak_bitrate` 1–245 Mbit/s（默认 20 M）；帧级码控开关 |
| GOP 与帧类型 | `video_gop_size`（默认 59）；`video_b_frames` 0–1（默认 0） |
| H.264 | profile Baseline / Constrained Baseline / Main / High（默认）/ Constrained High；level 1 到 6.0（默认 5.0）；熵编码 CAVLC / CABAC（默认）；I/P/B 帧 QP（默认 20）；QP 上下限（默认 1 / 51） |
| HEVC | profile Main / Main Still Picture / Main 10；level（默认 5）；tier；各帧 QP；`prepend_sps_and_pps_to_idr` |
| 头的模式 | `sequence_header_mode`：单独一个缓冲，或和第一帧合在一起（默认） |
| 流中可改的控件 | 码率、峰值码率、GOP、各帧类型 QP、帧内刷新周期、长期参考帧相关、翻转都带 `CAP_FLAG_DYNAMIC_ALLOWED`：流中修改会立刻下发给固件（`iris_ctrls.c` 的 `iris_op_s_ctrl`）。没有这个标志的控件（QP 上下限等）流中改会得到 `-EINVAL` |
| **没有的** | `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`（驱动源码里没有这个控件） |

### 1.2 固件码流的实际样子

用 ffmpeg 9.1 的 `h264_v4l2m2m` 编 `testsrc2`，再用 `trace_headers` 解析。原始输出在
`liuqin-study/raw/vaenc-eval/phone-encoder-2026-11-27.txt`（工作区，不在仓库内）。

- **头是固件自己写的。** 720p、VBR 4 Mbit/s、GOP 30 的 H.264 流：High profile，Level 5.0，
  `pic_order_cnt_type = 2`，`log2_max_frame_num = 4`，1 个参考帧，CABAC，`transform_8x8_mode_flag = 1`，
  VUI 里带 30 fps 的时序信息，`pic_init_qp_minus26 = -6`。没有 AUD 和 SEI。
- **NAL 顺序**：SPS、PPS、IDR、P……，帧类型 I P P …，每 30 帧一个 I。
- **SPS/PPS 默认只在流开头出现一次**（150 帧 5 个 IDR，只有 1 组 SPS/PPS）。WebRTC 要求每个
  IDR 自带头，驱动要负责（参考驱动的做法见 3.2）。
- **对齐和裁剪由固件完成**，编码尺寸按 16 对齐，多出来的用帧裁剪去掉：

  | 请求 | 编码尺寸 | 裁剪 |
  | --- | --- | --- |
  | 960×540 | 960×544 | 下 4 |
  | 854×480 | 864×480 | 右 10 |
  | 1280×696 | 1280×704 | 下 8 |
  | 1920×1080 | 1920×1088 | 下 8 |
  | 640×480 | 640×480 | 无 |

  130×130、176×144、254×130 也能编，不报错。
- **HEVC**：Main profile，Level 5.0；编码尺寸 1280×736，用 conformance window 裁到 720；一帧
  多个条带；SAO 和 temporal MVP 开着。
- **速度**（ffmpeg，含 CPU 上传和帧生成）：720p 301 帧 0.46 秒（约 650 帧/秒），1080p 301 帧
  0.88 秒（约 340），4K 61 帧 0.86 秒（约 70）。
- **码率精度**（`testsrc2`，短片）：要 4 Mbit/s 得 4.28–4.48，要 8 得 8.80，要 20 得 24.6。项目
  之前测 CBR 是 4000 得 4260（`release/driver-fix-batch4-iris-encoder/README.md`）。

### 1.3 浏览器为什么显示 "Video Encode: Software only"

- Chromium 在 Linux 上靠 VA-API 做硬件编码：问驱动“哪些 profile 有编码入口点
  `VAEntrypointEncSlice`”。我们现在装的 `libva-v4l2-stateful`（CIX 的 Sky1 驱动加两个补丁）
  是纯解码架构，`vainfo` 里七个 profile 全是 `VAEntrypointVLD`。答案是空，所以是 Software only。
- 这和 Vulkan 无关：Vulkan 是图形渲染那条线（`chrome://gpu` 的 "Vulkan" 一行是 Chromium 的
  Vulkan 合成 feature）。
- 即便驱动有了编码入口点，Chromium 在 Linux 上默认也不创建 VA-API 编码器：见 2.1。

### 1.4 ffmpeg 那条路

ffmpeg 不经过 VA-API，直接用 V4L2 m2m（`h264_v4l2m2m`、`hevc_v4l2m2m`），现在就能用
（`ubuntu-diting/ci/FFMPEG.md`）。浏览器不走这条路，Chromium 里对应的 V4L2 编码器只在
ChromeOS 上编译。

## 2 Chromium 在 Linux 上怎么用 VA-API 编码

以下都是 Chromium 分支 `8127` 的源码事实。文件在
`liuqin-study/raw/vaenc-eval/chromium-8127/`（工作区）。

### 2.1 启用条件

`media/gpu/gpu_video_encode_accelerator_factory.cc`：Linux 上 `CreateVaapiVEA()` 先查
feature，没开就返回空：

```cpp
#if BUILDFLAG(IS_LINUX)
  if (!base::FeatureList::IsEnabled(kAcceleratedVideoEncodeLinux)) {
    return nullptr;
  }
#endif
```

`media/base/media_switches.cc`：这个 feature 的名字是 **`AcceleratedVideoEncoder`**，默认关闭。
所以参数是 `--enable-features=AcceleratedVideoEncoder`（和我们已有的
`VaapiVideoDecoder,VaapiIgnoreDriverChecks,…` 写在同一个列表里）。

### 2.2 创建编码器时向驱动要什么

- `vaCreateConfig` 只传三类属性（`vaapi_wrapper.cc` 1049–1077）：`VAConfigAttribRTFormat`
  （YUV420）、`VAConfigAttribRateControl`（CBR、VBR 或 CQP 三选一）、H.264 的
  `VAConfigAttribEncPackedHeaders`。
- 打包头的取值：先问驱动支持哪些；**只有驱动同时支持序列、图像、条带三种打包头，才请求
  打包头**，否则传 `VA_ENC_PACKED_HEADER_NONE`。
- 查 `VAConfigAttribEncMaxRefFrames`，必须大于 0；H.264 的参考帧数取
  `min(2, 驱动报的值)`（`vaapi_video_encode_accelerator.cc` 417–424）。

### 2.3 H.264 的约束（`h264_vaapi_video_encoder_delegate.cc`）

- profile：Baseline（按 Constrained Baseline 处理）、Main、High。
- 编码尺寸按 16 对齐，可见尺寸和编码尺寸不同时用帧裁剪。level 先按配置的校验，不够就往上找
  一个合法的。
- 时间层：单层；配了 2–3 层的话需要驱动支持打包原始数据（放 prefix NALU），否则初始化失败。
- 打包头：驱动不支持就不提交，日志是 "Packed headers are not submitted to a driver"（454–474）。
- PPS：Main 和 High 用 CABAC，Baseline 用 CAVLC；`num_ref_idx_l0_default_active_minus1 =
  max_ref_pic_list0_size - 1`，单参考帧时是 0；High 开 `transform_8x8`。
- 软件码控只在 ChromeOS 上有（541–565），Linux 上码率控制交给驱动。

### 2.4 每帧提交什么（996–1188）

`SubmitFrameParameters` 一次提交：

- `VAEncSequenceParameterBufferH264`：尺寸、level、`max_num_ref_frames`、`intra_period = 0`、
  `intra_idr_period = 2048`、`ip_period = 1`、`bits_per_second`、VUI 时序。
- `VAEncPictureParameterBufferH264`：`idr_pic_flag`、`reference_pic_flag`、熵编码标志、
  `pic_init_qp`、`num_ref_idx_l0_active_minus1`、参考帧列表。
- `VAEncSliceParameterBufferH264`：**一个**条带，覆盖整帧，`macroblock_address = 0`，
  `cabac_init_idc = 0`，`RefPicList0[0]` 是上一帧。
- 没有逐帧 QP 时再加三个 misc 参数：RateControl（码率、目标百分比、窗口、初始/最小/最大
  QP）、FrameRate、HRD。
- 驱动支持打包头时才有序列头、图像头、条带头三种打包缓冲；不支持就没有。

### 2.5 关键帧

`PrepareEncodeJob`（583–601）：首帧、上层请求关键帧、或编码参数变了，就把这一帧标成 IDR；
另外每 2048 帧自己标一次（`kIDRPeriod = 2048`）。**每个 IDR 都带 `idr_pic_flag` 提交**，驱动照
做即可，不需要自己定 GOP。

### 2.6 码率和帧率更新

`UpdateRates`（703–763）只改内存里的参数，**不重建上下文**；下一帧的序列参数和 misc 参数自然
带上新值。Chromium 还特意不为“只改码率帧率”强制出 IDR。

### 2.7 SPS/PPS 怎么交给对方

`H264Metadata`（`media/video/video_encode_accelerator.h` 47–55）只有 `temporal_idx` 和
`layer_sync`，**没有 SPS/PPS 字段**。也就是说 Chromium 不把头带到带外，对端从头在带内的码流里
拿。驱动给的 SPS/PPS 是谁的都可以，只要和条带数据是同一套。

### 2.8 输入帧

- 只收 I420 和 NV12 两种格式（`vaapi_video_encode_accelerator.cc` 267–276）。
- 共享内存里的 CPU 帧（`CreateSurfacesForShmemEncoding`，704–750）：驱动分配一个 surface，
  `vaDeriveImage` 得到 NV12 image，`vaMapBuffer` 映射，用 libyuv 把 I420 转成 NV12 写进去。
  `vaDeriveImage` 不行时退到 `vaCreateImage` + `vaPutImage`。
- GPU 上的原生帧：包成 DMA-BUF surface 导入（`CreateVASurfaceForPixmap`）。

### 2.9 它告诉上层的编码器能力

`implementation_name = "VaapiVideoEncodeAccelerator"`，`has_trusted_rate_controller = true`
（只有 Intel 驱动被标成不可信），`supports_native_handle`，不支持 simulcast（171–175）。

## 3 参考实现：qcom-va-driver

### 3.1 项目概况

| 项 | 值 |
| --- | --- |
| 仓库 | <https://github.com/radxa-pkg/qcom-va-driver>（`strongtz/libva-v4l2` 是同一提交的镜像；旧名 libva-v4l2） |
| 版本 | `ee8622c`（2026-11-17），57 个提交，标签 v1.0.0 / v1.1.0 / v1.1.1；2026-11-25 还有提交 |
| 许可 | 驱动 MIT；随附的内核补丁 GPL-2.0 |
| 语言与规模 | C++17，约 6500 行：`backend.cpp` 1310、`encoder.cpp` 901、`vpp.cpp` 617、`hevc.cpp` 581、`decoder.cpp` 492 |
| 构建依赖 | Meson ≥ 0.61、Ninja、libva ≥ 1.10、libdrm；可选 EGL、GLES 3.2、GBM（GPU 拷贝）、Vulkan + glslang（VPP） |
| 安装名 | `qcom_drv_video.so`，自动带 `msm` 别名，默认还带兼容软链 `v4l2_drv_video.so` |
| 运行时开关 | `IRIS_VAAPI_DEVICE`、`IRIS_VAAPI_ENCODER_DEVICE`、`IRIS_VAAPI_COPY`（`gpu` 或 `cpu`）、`IRIS_VAAPI_DEBUG=1` |
| 功能 | 解码 H.264 / HEVC（含 Main10）/ VP9 / AV1；编码 H.264（三种 profile）和 HEVC Main，CQP/CBR/VBR；可选的视频前后处理（CDSP 或 Vulkan） |
| 测过的 | 解码：FFmpeg、GStreamer、mpv、VLC、Chromium、Kodi。编码：FFmpeg、GStreamer、Sunshine |

注意：CDSP 的视频处理默认是开的，需要 ARM64 构建机、GHC 和 Hexagon 工具链，我们用不到，构建
时要 `-Dcdsp_vpp=disabled`。

### 3.2 编码器做了什么（`src/encoder.cpp`）

- **找设备**：遍历 `/dev/video*`，驱动名是 `iris_driver`、多平面 m2m、CAPTURE 队列有 H264 的就是
  编码器。不写死路径（我们的解码驱动写死了，见 KNOWN_ISSUES）。
- **对客户端的要求**（`validate_h264`，76–113）：一个序列参数、一个图像参数、**一个条带**；
  尺寸和上下文一致；逐行、8-bit、4:2:0；`max_num_ref_frames <= 1`；I 或 P 条带且覆盖整帧；
  不许加权预测、缩放矩阵、色度 QP 偏移；`num_ref_idx_l0_active_minus1` 必须是 0；
  `cabac_init_idc` 必须是 0；帧率 1–240 fps；只支持紧跟在后面的那一帧做参考；所有帧都得是参
  考帧。不满足就返回 `VA_STATUS_ERROR_UNIMPLEMENTED`。
- **会话创建时设的控件**（640–655）：profile（Constrained Baseline / Main / High）、level、
  熵编码；B 帧设 0；**GOP 设成 `INT_MAX`**，不让固件自己出 IDR；头和第一帧合并；
  `PREPEND_SPSPPS_TO_IDR = 1`；按码控模式设 CBR/VBR、码率、峰值码率；QP 上下限。
- **关键帧**（860–861）：客户端要 IDR 时，先把流水线排空，再写
  `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`。注释写明 Iris 只暴露这一个控件。
- **输入帧**：NV12。只有当来源内存是一致性内存、且步长和存储高度都和编码器协商的一致时才
  直接送 DMA-BUF；否则先用 GPU（EGL/GLES）或 CPU 拷进编码器自己的缓冲。编码器的输入缓冲高
  度是补齐过的（720p 是 736 行），Chromium 的帧不是，所以基本都会走拷贝。
- **输出**：MMAP 的 CAPTURE 缓冲，用时间戳令牌对应到每一帧，拷进 VA 的编码缓冲。
- **不支持改参数**（733–744）：level、熵编码、帧率、码率、峰值码率、QP 范围，任何一项和创建
  时不同就报 "changing encoder settings requires a new context"。只有 CQP 模式下逐帧改 QP 是
  支持的（排空后改控件）。

### 3.3 内核补丁依赖，对照我们的内核

| 它带的补丁 | 作用 | 我们的内核（7.2.10 加项目补丁） |
| --- | --- | --- |
| 0001 decode-order output | gen2 解码器支持零显示延迟 | **已有**：`DISPLAY_DELAY_ENABLE` 的 `hfi_id` 就是 `HFI_PROP_DECODE_ORDER_OUTPUT`；手机上设 `display_delay_enable=1,display_delay=0` 被接受 |
| 0002 capture pool | 解码 CAPTURE 队列上限 32 → 64 | 没有。只在客户端要 32 个以上解码缓冲时才会报 "CAPTURE pool too small" |
| 0003 deblocking controls | 编码器去块滤波控件 | 没有。可选：客户端请求的是默认的 0/0/0 时不要求它 |
| 0004 timestamps on error | 出错的解码缓冲保留时间戳 | **已有**（`iris_buffer.c`，项目自己的实现） |
| 0005 NOSHOW recycling | AV1 的不显示帧回收 | 只用于 AV1，我们的解码器没有 AV1 |
| 强制关键帧 | 它没带补丁，假设内核已有 | **没有**。上游有专门的补丁，见 6.1 |

### 3.4 性能（它的 README，SC8280XP）

FFmpeg VA-API 编码 HEVC：720p 1289 帧/秒，1080p 714，4K 206（含 CPU 上传，`async_depth=4`）。

## 4 逐项对照

| # | Chromium 的要求 | 参考驱动 | 结论 |
| --- | --- | --- | --- |
| 1 | Linux 上要开 feature `AcceleratedVideoEncoder` | 无关 | 配置项，加到 `~/.chromium-browser.init` |
| 2 | `vaCreateConfig` 传三类属性 | 接受 | ✓ |
| 3 | 查 `EncMaxRefFrames`，须大于 0 | 报 1 | ✓ |
| 4 | profile CBP / Main / High | 都有 | ✓ |
| 5 | 16 对齐加裁剪 | 校验一致；固件自己裁 | ✓ |
| 6 | 驱动不全支持打包头就不提交 | 报 `VA_ENC_PACKED_HEADER_NONE` | ✓ 头由固件生成 |
| 7 | SPS/PPS 不带到带外 | 固件的头在带内，每个 IDR 前重复 | ✓ |
| 8 | 序列、图像、一个条带，加码控/帧率/HRD | 都接受，HRD 忽略 | ✓ |
| 9 | 单条带整帧、无 B 帧、`cabac_init_idc = 0`、单参考帧 | 校验允许 | ✓ |
| 10 | 首帧、按请求、每 2048 帧出 IDR | 用 `FORCE_KEY_FRAME` 控件 | **缺口：内核没有这个控件** |
| 11 | 码率帧率变了不重建上下文 | 拒绝 | **缺口：驱动要补** |
| 12 | 两层以上时间层要打包原始数据 | 不支持 | 不支持，Chromium 会初始化失败 |
| 13 | 输入帧 I420/NV12，`vaDeriveImage` 加映射，或 DMA-BUF 导入 | 有 `derive_image`、I420、NV12；布局不匹配走暂存拷贝 | ✓，性能待测 |
| 14 | 去块滤波 0/0/0 | 默认即通过 | ✓ |
| 15 | HEVC | Linux 版没有编码路径 | 用不上 |

## 5 方案比较与推荐

### 5.1 四个方案

| 方案 | 做法 | 好处 | 代价 |
| --- | --- | --- | --- |
| **A. 整体换驱动** | 用 qcom-va-driver 替换 libva-v4l2-stateful，解码编码都用它 | 不用移植代码；能跟上游；解码顺带得到 10-bit、B 帧、错误隐藏 | 解码要重新验证；内核要补关键帧控件，可能还要 0002；上游变动快（周级提交） |
| **B. 只移植编码器** | 把它的 `encoder.cpp`、`surface-copy.cpp`、`cpu-copy.cpp`、`msm.c` 和相关的结构体接进 libva-v4l2-stateful | 解码一行不动；内核只补关键帧控件 | 约 1500 行 C++ 进一个 C 代码库，外加胶水层；以后靠手工同步上游 |
| C. 从零写 | 在 libva-v4l2-stateful 里直接写 VA-API 编码 | 完全可控 | 工作量是 B 的两倍以上，没有额外好处 |
| D. 自建 Chromium | 编译时打开它现成的 V4L2 编码器（ChromeOS 用的那条） | 浏览器原生路径 | 要自己维护 Chromium 构建，snap 用不了 |

### 5.2 推荐

**先按 A 的用户态做验证，最后一步再决定 A 还是 B。** 理由：编码器和解码器在驱动里只通过 VA
的公共管线相连，编码这一半可以在**不动内核、不动现有解码**的前提下先试出来；而 A 和 B 的
分叉点只在解码回归的结果上。

- 解码回归通过（和软解逐帧一致、浏览器播放正常）→ A，一个驱动管全部。
- 不通过，或者不想为这件事再动解码侧的内核补丁 → B。

## 6 要做的改动

### 6.1 内核：回移强制关键帧

上游补丁：高通 Wangao Wang 的系列 "add dynamic encoder properties" v4 的 2/2
"Add request key frame support for encoder"（2026-07-23，Reviewed-by Bryan O'Donoghue、
Vishnu Reddy）。gen2 部分：

- `iris_platform_common.h`：`enum platform_inst_fw_cap_type` 加 `REQUEST_SYNC_FRAME`。
- `iris_hfi_gen2_defines.h`：`enum hfi_syncframe_request_mode`（不带头 1、带 SPS/PPS 头 2）和
  `#define HFI_PROP_REQUEST_SYNC_FRAME 0x03000145`。
- `iris_hfi_gen2.c`：编码器能力表加一项，`min 0`、`max 1`、`hfi_id = HFI_PROP_REQUEST_SYNC_FRAME`、
  `flags = CAP_FLAG_INPUT_PORT | CAP_FLAG_DYNAMIC_ALLOWED`、`set = iris_set_req_sync_frame`。
- `iris_ctrls.c`：控件号和 cap 的双向映射；`iris_set_req_sync_frame` 按
  `PREPEND_SPSPPS_TO_IDR` 的值选模式，用 `session_set_property` 发下去。

合计约 43 行。要注意的：

- 加到 **SM8450 编码器实际用的那张能力表**里（`iris_hfi_gen2.c` 里有好几张
  `inst_fw_cap_*_enc[]`，具体哪张待核实）。
- 我们的 0127、0128、0129、0134 都改过编码器的能力表和相关路径，可能要手工合。
- 验证：`v4l2-ctl -d <编码器节点> --list-ctrls` 里出现这个控件；参考驱动不再在关键帧上报错。

走方案 A 的话再评估 0002（3 行，只在要 32 个以上解码缓冲时有用）。0003、0004、0005 不需要。

### 6.2 用户态驱动：运行时改参数

在 `Encoder::encode` 里把“参数变了就拒绝”改成“排空流水线后下发新值”，照它已有的 CQP 改
QP 的写法：

- 码率和目标百分比：`V4L2_CID_MPEG_VIDEO_BITRATE_PEAK`、`V4L2_CID_MPEG_VIDEO_BITRATE`。
  内核把这两个标成了流中可改。
- 帧率：`VIDIOC_S_PARM`。内核的 `iris_venc_s_param` 里没看到检查是否在流中的代码，待核实。
- QP 上下限：内核不允许流中改。Chromium 一个会话里不变，保持创建时的值即可；客户端真要
  改就只能报错。
- 同时更新它记着的 `settings`，让下一帧的检查通过。

固件收到流中的码率变更后是否真的调整，待核实（第 10 节第 3 条）。

### 6.3 打包与集成

- 仓库里加一个包（照 `libva-v4l2-stateful` 的做法：`packages/` 下放 debian 目录和补丁，
  `scripts/build-*.sh` 走 arm64 构建 chroot，`Makefile` 加目标，`make rootfs` 依赖它）。它自
  带 debian 打包，可以拿来改。
- 构建 chroot 现在不在构建服务器上（`work/build-chroot-resolute-arm64` 是在手机上建的，清空后
  没了）。动工前要先建。
- snap 的 Chromium 看不到主机的驱动，靠 `diting-chromium-vaapi` 把驱动拷进
  `~/snap/chromium/common/dri/` 并设 `LIBVA_DRIVER_NAME=v4l2`。qcom-va-driver 默认带
  `v4l2_drv_video.so` 软链，拷贝逻辑可以不动；要核实它在 snap 自带的 Mesa（26.0.3，主机是
  26.0.8）和 core26 的 libstdc++ 里能不能加载。
- `~/.chromium-browser.init` 的 feature 列表加 `AcceleratedVideoEncoder`。这个文件只在不存在时
  才生成，已经装好的手机要手工改。

### 6.4 Chromium

不用改 Chromium，只有 6.3 里那一个开关。

## 7 工作分解与估时

人日是粗略估计，没算固件出问题后的恢复时间。

| 阶段 | 内容 | 估时 |
| --- | --- | --- |
| S0 验证，不动内核 | 建 chroot；编译 qcom-va-driver（关 CDSP 和 Vulkan）；手机上 `vainfo` 出现 `VAEntrypointEncSlice`；跑它自带的编码器测试；Chromium 开开关，用 WebCodecs 编一段 | 2–3 |
| S1 内核关键帧 | 6.1，按内核流程走：本地写补丁、rsync、容器里编译、刷机、回归 | 1–2 |
| S2 驱动补丁 | 6.2；在 Chromium 里测 Meet 或两个标签页互推 | 3–5 |
| S3-A 解码回归 | 换驱动后跑现有的解码脚本（`probe-video*.sh`，和软解逐帧比摘要）和浏览器播放；按需加 0002 | 2–4 |
| S3-B 编码器移植 | 方案 B 才做：胶水层加拷贝路径 | 5–10 |
| S4 收尾 | 包、`make verify` 的检查、KNOWN_ISSUES、这个文档改成实施记录 | 1–2 |

合计：A 约 9–16 人日，B 约 12–22 人日。S0 的结果决定后面还值不值得做。

## 8 测试计划

- **驱动级**：`vainfo` 的 H.264 和 HEVC profile 下出现 `VAEntrypointEncSlice`；它自带的
  `tests/encoder/ffmpeg-smoke.py`（profile、码控、尺寸、帧数、关键帧）、`api-smoke.cpp`（上传、
  直接和暂存输入、被拒绝的请求）、`async.cpp`（QP 和 IDR 变更、超时）；ffmpeg 的
  `h264_vaapi` 跑一遍 1.2 节的尺寸和码率用例，和 V4L2 直编的结果对比。
- **内核级**：控件出现；流中请求 IDR 后下一帧确实是 IDR（`ffprobe` 看帧类型）；内核日志没有
  iris、SMMU、videobuf2 的新内容；空闲后视频核回到 `suspended`。
- **Chromium**：`chrome://gpu` 的 Video Encode 变成 Hardware accelerated；WebCodecs
  `VideoEncoder.isConfigSupported()` 报支持，并真的编出 H.264；两个标签页互推视频，期间
  `ls -l /proc/<GPU 进程>/fd` 能看到编码器节点被打开，CPU 占用明显低于软编；中途加入第三方
  （触发关键帧请求）、限速（触发码率变更）都不回退软编。
- **解码回归**（方案 A）：现有解码脚本全部重跑，VA-API 解码和软解逐帧摘要一致。
- **收尾纪律**：任何一次固件崩溃之后，按 KNOWN_ISSUES 的要求 `poweroff` 加冷启动。

## 9 风险与限制

1. **参考驱动没在 Chromium 上验证过编码**，也没在 SM8475 的固件上跑过。S0 就是去看这个。
2. **没有关键帧控件就没有可用的视频通话。** 首帧的 IDR 靠新开会话能有，之后的只能等 2048 帧。
   S1 之前只能验证首段。
3. **码率控制的实时性**。固件的 VBR 在 `testsrc2` 上高出目标 7–23%；真实会议画面、每帧延迟、
   峰值都待测。Chromium 把驱动的码控当成可信的，不做二次控制。
4. **解码回归**（方案 A）。现在的浏览器硬解是花了几天稳定下来的，参考驱动对同一个固件怪癖
   （空缓冲、不显示帧、会话上限）有它自己的一套处理。
5. **固件崩溃的风险**随每一次编码实验存在，见 KNOWN_ISSUES。
6. **上游变动快**：参考驱动周级提交，Chromium 的 feature 名和 VA 用法随版本变（这里只核对了
   158）。snap 自动更新后要重测。
7. **每帧的拷贝开销**：I420 转 NV12 一次，布局不匹配再拷一次。720p 估计每帧几毫秒的 CPU 或
   GPU，待测。
8. **snap 里的加载环境**和主机不同（自带的 Mesa 和 libstdc++），驱动拷进去以后未必能加载。

## 10 待核实

1. qcom-va-driver 在我们的内核和固件上能不能编译、加载、开会话（S0 第一步）。
2. 强制关键帧的补丁加到哪张能力表；和 0127–0129、0134 有没有冲突。
3. 固件收到流中的码率变更后是否真的调整输出码率，多久生效。
4. 帧率流中修改（`VIDIOC_S_PARM`）内核是否允许，固件是否生效。
5. Chromium 在 Linux 上给 WebCodecs 选不选硬件编码器；WebRTC 给 H.264 选不选。
6. 第一帧延迟、请求关键帧到出帧的延迟。
7. 编码器输入缓冲的步长和存储高度（参考驱动的日志会打印），Chromium 的帧离它有多远。
8. 驱动拷进 snap 后能不能加载（依赖是否都能在 snap 自带的库里解析）。
9. 0002 到底需不需要：Chromium 和 Firefox 的 VA 解码各要多少个 CAPTURE 缓冲。
10. 对端的硬件解码器（Android、iOS 上的浏览器）能不能解固件写的这路流：POC type 2、
    `log2_max_frame_num = 4`、High profile。
11. Chromium 的 GPU 进程编 720p30 时 CPU 和 GPU 的实际占用。

## 11 出处

- Chromium 源码（分支 `8127`，`https://chromium.googlesource.com/chromium/src/+/refs/branch-heads/8127/`）：
  `media/gpu/gpu_video_encode_accelerator_factory.cc`、`media/base/media_switches.cc`、
  `media/gpu/vaapi/vaapi_video_encode_accelerator.cc`、
  `media/gpu/vaapi/h264_vaapi_video_encoder_delegate.cc`、`media/gpu/vaapi/vaapi_wrapper.cc`、
  `media/video/video_encode_accelerator.h`、`media/gpu/vaapi/BUILD.gn`。
- qcom-va-driver：<https://github.com/radxa-pkg/qcom-va-driver>，提交 `ee8622c`；README、
  `src/encoder.cpp`、`src/backend.cpp`、`patches/`、`tests/README.md`。
- 强制关键帧的上游补丁：
  <https://lore.kernel.org/linux-media/20260723-dynamic_encode-v4-0-5fd6bd549ead@oss.qualcomm.com/>
- V4L2 stateful 编码器接口：
  <https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/dev-encoder.html>
- 我们这边的内核源码：构建服务器 `work/kernel-src/drivers/media/platform/qcom/iris/`（已应用
  项目补丁）。
- 项目内：`ubuntu-diting/docs/KNOWN_ISSUES.md`（"Video encoding"）、`ubuntu-diting/ci/FFMPEG.md`、
  `docs/liuqin-study/VIDEO_DECODE.md`。
- 原始材料（工作区 `liuqin-study/raw/vaenc-eval/`，不在仓库内）：`phone-encoder-2026-11-27.txt`
  （手机上的码流解析、控件、速度）、`chromium-8127/`（下载的 Chromium 源文件）、
  `qcom-va-driver/`（`ee8622c` 的副本）、`libva/`（libva 头文件）。

## 12 实施记录（2026-11-27）

这一天做完了 S0（不动内核的验证）和 S1（内核的关键帧控件，0137：已上机、已提交），并且做了
评估里没有的事：上游驱动带着三个缺陷，在这颗固件上一个是码控完全失效、一个是视频通话用不了、
一个是请求的关键帧偶尔晚一帧，都已经在 `packages/qcom-va-driver/patches` 里修掉并在手机上验证。
**Chromium 在这台手机上用不上它**：不是驱动的问题，是 GBM 分配不了 NV12（12.7）。上午的记录在
12.1–12.5，下午 0137 上机之后的两件事在 12.7，读的时候以它为准。

### 12.1 仓库里有什么

| 位置 | 内容 |
| --- | --- |
| `ubuntu-diting/packages/qcom-va-driver/` | `debian/`（我们自己写的，不用上游的：关掉 GPU 拷贝、CDSP、Vulkan，不带 `v4l2` 名字）和 `patches/`（0001、0002、0003，见 12.3 和 12.7） |
| `ubuntu-diting/packages/qcom-va-driver/patches/0002` | 还带一个测试程序 `tests/encoder/rate-change`：一个会话、一个关键帧，码率改两次、帧率改一次 |
| `ubuntu-diting/packages/qcom-va-driver/patches/0003` | 还带 `tests/encoder/async-dump`：同一串帧四种编法，码流必须逐字节相同（12.7） |
| `scripts/build-qcom-va-driver.sh`、`make qcom-va-driver` | 照 `libva-v4l2-stateful` 的做法：`git archive` 上游、放上补丁、在 arm64 chroot 里 `dpkg-buildpackage` |
| `config/diting.conf` | `QCOM_VA_DRIVER_URL`、`QCOM_VA_DRIVER_COMMIT`（`ee8622c`）；`fetch-sources.sh` 认识这个名字，`ci/tests.sh` 的计数跟着改成 17 |
| 两个 deb | `qcom-va-driver`（只有 `/usr/lib/aarch64-linux-gnu/dri/qcom_drv_video.so`）、`qcom-va-driver-tests`（上游的硬件测试加 `rate-change`，在 `/usr/libexec/qcom-va-driver/tests/`） |

**它不在镜像里**：`make rootfs` 不依赖它，`build-rootfs.sh` 不装它。方案（5.1 的 A 还是 B）定下来
之前不进镜像。手机上是用 `dpkg -i` 装的 `1.1.1+gitee8622c-0diting3`，和 `libva-v4l2-stateful`
并装；程序用 `LIBVA_DRIVER_NAME=qcom` 才选它，浏览器照旧用旧驱动。

**怎么建**。构建服务器是 x86_64 的 Debian 13，主机上只有 git、docker、rsync、tmux。chroot 在
`ci/Dockerfile.ffmpeg` 那个容器里建（`ci/ffmpeg.sh`：它是仓库里现成的“特权 chroot 构建容器”，
名字叫 ffmpeg 只是因为先给 ffmpeg 建的）：

```sh
export DOCKER="sudo docker"
ubuntu-diting/ci/ffmpeg.sh build && ubuntu-diting/ci/ffmpeg.sh up
# 一次就够，主机重启后要重来：在容器里登记 qemu-aarch64 的 binfmt
sudo docker exec -u 0 diting-ffmpeg sh -ec '
	mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
	sed "s|:/usr/libexec/qemu-binfmt/aarch64-binfmt-P:.*|:/usr/bin/qemu-aarch64-static:F|" \
		/usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register'
ubuntu-diting/ci/ffmpeg.sh make qcom-va-driver     # 容器内 tmux，日志 output/logs/
```

trixie 的 `qemu-user-static` 走 systemd 的 `binfmt.d`，登记的解释器是一个再去按路径找 qemu 的
包装程序（标志 `OPF`），进了 chroot 就找不到 qemu。`update-binfmts` 的数据库里也没有它。
所以要自己登记静态的 qemu 本身，带 `F` 标志（`docs/BUILD.md` 里 openSUSE 那一段的做法）。
debootstrap 在 qemu 下约 6 分钟，一次编译约 6 分钟。

### 12.2 在手机上验证了什么

1. **加载和会话**。`LIBVA_DRIVER_NAME=qcom vainfo` 列出 H.264（Constrained Baseline、Main、High）
   和 HEVC Main 的 `VAEntrypointEncSlice`。编码器是 `/dev/video7`，720p 时 `stride=1280
   storage-height=736`，驱动自己分配的 surface 直接以 DMA-BUF 送进去（`input path=direct`）。
2. **单 GOP 矩阵**（定稿的包 `0diting3`）：h264/hevc × 三种 profile × CQP/CBR/VBR × 六种尺寸
   （1280×720、1920×1080、960×540、854×480、640×480、130×130），加 4K。74 条流每条帧数完整、
   恰好一个关键帧、只有 I 和 P，每一帧都是 `input path=direct`（零拷贝）。CBR 要 4 Mbit/s 的在
   3911–3992 之间，VBR 要 2 Mbit/s 的在 1.6–2.6 Mbit/s 之间（130×130 画面太小，用不到这么多）；
   PSNR 38–58 dB。内核日志 0 行，核心随即挂起。
3. **码控**（H.264 High，720p，150 帧，`testsrc2`；上游原样就是 0001 之前）：

   | 模式 | 要的 | 上游原样 | 带 0001 |
   | --- | --- | --- | --- |
   | CBR | 1 Mbit/s | 734 | 998 |
   | CBR | 4 Mbit/s | 734 | 3977 |
   | CBR | 20 Mbit/s | 734 | 13784 |
   | VBR | 4 Mbit/s | 911 | 4143 |
   | VBR | 16 Mbit/s | 2077 | 5269 |
   | HEVC Main，CBR | 4 Mbit/s | 230 | 3965 |

   20 Mbit/s 得 13.8 是内容的上限：同一内容恒定 QP 24 只要 5 Mbit/s。
4. **流中改码率和帧率**（`rate-change`，720p，四段一个会话、只有一个关键帧）。0002 之前第一段
   编完就被拒：`changing encoder settings requires a new context`。之后：

   | 阶段 | 要的 | H.264 High，CBR | H.264 High，VBR | HEVC Main，VBR |
   | --- | --- | --- | --- | --- |
   | 30 fps | 1 Mbit/s | 990 | 1500 | 1440 |
   | 30 fps | 3 Mbit/s | 2970 | 2670 | 2910 |
   | 30 fps | 1 Mbit/s | 960 | 1290 | 1350 |
   | 15 fps | 2 Mbit/s | 1890 | 1350 | 1470 |

   （kbit/s，一段 150 帧，最后一段 75 帧；VBR 传的峰值是目标的两倍。）CBR 四段都在目标的 5%
   以内。15 fps 那段每帧字节数翻倍而每秒码率对上目标：帧率变了之后码控跟着时间戳走。
   内核日志 0 行。
5. **解码回归**（同一批片子，软件解码的逐帧 md5 当基准，和现有驱动并排比）：

   | 片子 | 输出 | `libva-v4l2-stateful` | `qcom-va-driver` |
   | --- | --- | --- | --- |
   | H.264 1080p、4K，HEVC 1080p，VP9 1080p，6 参考帧 4 B 帧的 720p | NV12 | 一致 | **一致** |
   | HEVC Main10 4K、VP9 profile 2 | P010 | 失败 | **一致** |
   | 同一个进程里 seek 三次 | NV12 | — | 一致 |
   | 两个解码器加一个编码器同时跑 | NV12 | — | 都一致，编码 CBR 4 M 得 3992 |

   内核日志 0 行。ffmpeg 这一层的回归支持方案 A；**浏览器播放的回归没做**（需要桌面会话）。
6. **Chromium**（snap 158，不经启动器，`snap run --shell` 里自己给驱动名和 feature）：
   - snap 里能加载（libva 2.23、libdrm、libstdc++ 6.0.35 都在 snap 自己的 content 里）。
     10.8 有了答案。
   - 开 `AcceleratedVideoEncoder` 之后，WebCodecs 用默认的 `hardwareAcceleration: "no-preference"`
     就选硬件编码器：GPU 进程日志 `Initializing VAVEA, input_format: PIXEL_FORMAT_NV12, ...
     storage_type: GpuMemoryBuffer`，`UpdateRates`，然后 `setting state to: kEncoding`：
     **编码器初始化成功**。10.5 有了答案（WebRTC 没测）。
   - 然后渲染进程里 `VideoEncodeAcceleratorAdapter` 报 5 次 `Unable to create a mappable shared
     image`，一帧都没送到编码器，回退到 OpenH264。Chromium 158 在 Linux 上固定按 GPU 缓冲送帧
     （`StorageType::kGpuMemoryBuffer`）：来源帧已经是 GPU 共享图像就直通；来自内存的帧（2D
     画布、I420 字节）要先装进一个 CPU 可写的 GPU 缓冲（`VEA_READ_CAMERA_AND_CPU_READ_WRITE`），
     这一步在这台手机的 snap 里做不成。原因下午查清了：GBM 分配不了 NV12（12.7）。无头模式的
     Chromium 根本不碰 VA-API。
   - 顺带：测试用的那段视频是 Chromium 经 qcom 驱动**硬解**出来的（240 帧），播放对不对没看。

另外记一条：驱动初始化时把 `/dev/video*` 全开一遍再关，共 5 次。那天有两次，都是紧跟在一次
`vainfo` 之后（一次在装完包后，一次在一轮测试的开头），核心没有立刻回到空闲：内核日志每 1.5 秒
一条 `failed to suspend`，第一次 42 秒里 14 条，第二次 3 条；别处同样的操作、连着 56 个只初始化的
进程、每一次真正的编码会话之后，都是干净地挂起。每次都自己恢复，没有再深究
（KNOWN_ISSUES）。

### 12.3 上游驱动的缺陷（上午找到的两个）

**0001：时间戳让码控失效。** `Encoder::encode()` 把 V4L2 时间戳当回配令牌：第 n 帧的戳是 n 微秒。
固件的码控按输入时间戳算每帧的预算，把它当成每秒一百万帧，于是顶到允许的最大 QP。二分是在
实验版驱动里用环境变量开关做的：关掉头模式、峰值码率、QP 范围、帧率、GOP 中的任何一个，CBR
都是 734；只把时间戳改成按帧间隔排，CBR 4 M 就得 3977。V4L2 直编（ffmpeg，给驱动的是帧自己的
时间戳）同一天测要 4 Mbit/s 得 4127，与此相符。修法：戳从上一个戳往后加一帧的间隔（按会话的
帧率），仍然唯一、仍然被固件原样带回来。

**0002：流中改码率被拒。** 6.2 写的事。排空之后下发 `BITRATE`、`BITRATE_PEAK` 和 `S_PARM`。
内核收 `S_PARM` 时不报错（更新 `frame_rate`、查上限、重算 level），但不会再给固件发帧率属性：
流里的时序信息还是会话开始时的那个，码率预算跟着时间戳走。QP 上下限、level、熵编码、去块滤波
仍然要新上下文（内核在流中拒绝 QP 上下限的控件）。

第三个缺陷（0003）是下午 0137 上机之后才露出来的，见 12.7。第四个（0004，I420 的 surface 被拒）
是晚上查 RustDesk 那条路时发现的，见 12.8。四个补丁都值得报给上游
（`radxa-pkg/qcom-va-driver`），还没报。

### 12.4 对评估的更正

- 3.2 “输出：MMAP 的 CAPTURE 缓冲，用时间戳令牌对应到每一帧”：这个令牌就是码控失效的原因。
- 3.3 的表和 6.1：能力表只有一张 `inst_fw_cap_sm8550_enc`，gen2 平台共用，SM8450 也用它。回移
  补丁（编为 0137）43 行，和 0127–0129、0134 没有冲突。已编出：`module-diff.py` 比对新旧两个包，
  1699 个模块里只有 `qcom-iris.ko` 不同，vmlinuz、config、System.map 一样，所以上机只要把模块
  放进 `updates/` 再重启，不用刷 boot。下午上机、验证、提交（`a21386e`），见 12.7。
- 4 的第 13 行（输入帧 I420/NV12，“性能待测”）：这台手机上 Chromium 根本递不了帧，GPU 来源帧
  也一样，因为递给编码器的帧必须是 GBM 做的 NV12 缓冲（12.7）。
- 5.1 方案 A 的“不用移植代码；能跟上游”：上游在这颗固件上带着三个缺陷，“跟上游”意味着每次
  重新带上 0001–0003，或者把它们推上去。
- 6.3：chroot 现在在构建服务器上（12.1）；snap 里能加载；`diting-chromium-vaapi` 和
  `~/.chromium-browser.init` 没动。
- 9.3 的码率数字是修好之后的：CBR 贴着目标，VBR 要 4 得 4.1；真实会议画面没测。

### 12.5 第 10 节的答复

| # | 问题 | 答复 |
| --- | --- | --- |
| 1 | 能不能编译、加载、开会话 | 能（12.2 第 1、2 条） |
| 2 | 补丁加到哪张表、有没有冲突 | `inst_fw_cap_sm8550_enc`；无冲突；已上机、已提交（12.7） |
| 3 | 流中改码率固件是否调整 | 调整：`rate-change` 的 3 Mbit/s 那段实得 2970 |
| 4 | 流中 `S_PARM` 是否允许、是否生效 | 内核允许，但不发给固件；预算跟着时间戳走，生效（15 fps 那段要 2 Mbit/s 得 1890） |
| 5 | Chromium 给 WebCodecs 选不选硬件 | 选（默认就是），但递不了帧（12.7）；WebRTC 没测 |
| 6 | 第一帧延迟、关键帧延迟 | 没测（Chromium 里没有硬件帧） |
| 7 | 编码器输入缓冲的步长和存储高度 | 720p：1280、736；Chromium 按 GPU 缓冲送帧，而那个缓冲在这台手机上做不出来 |
| 8 | 拷进 snap 能不能加载 | 能 |
| 9 | 0002 需不需要 | 没碰到；ffmpeg 一层没要过 32 个以上，浏览器没测 |
| 10 | 对端能不能解这路流 | 没测 |
| 11 | 720p30 时 CPU 和 GPU 的占用 | 没测 |

### 12.6 还没做的

1. **方案 A 还是 B**：它现在只是解码的问题（换不换驱动去解码）。编码这一半浏览器在这台手机上
   用不上，跟驱动无关（12.7）。ffmpeg 一层的解码回归通过；还差浏览器播放的回归。
2. **浏览器里用上硬件编码**：要上游动手，两条路任选其一（12.7）。不在仓库里。
3. **RustDesk 实测**：装上了，编码器这一半是通的，画面出不来——卡在手机的屏幕共享链路上
   （portal 后端崩溃、选择器 slurp 崩溃、没有 uinput），12.8。要它跑起来得先修那一链路。
4. 真实会议画面的码控、首帧和关键帧的延迟、对端解码器：只对用得上 VA-API 编码器的客户端有意义
   （比如装了 `gstreamer1.0-va` 的 GStreamer 应用）。
5. 四个补丁报给上游（报之前清掉 12.8 末尾那处编译警告）。
6. `qcom-va-driver` 进不进镜像：现在只是手机上手工装的。

### 12.7 下午：0137 上机之后

**上机**。带 0137 的模块 14:00 放进 `/lib/modules/7.2.10-diting/updates/`（手工放的；我的脚本用
`$HOME` 找模块，以 root 运行时找不到，已改成在脚本所在的目录里找），14:05 重启之后 `modinfo -n`
指向它，编码器节点（这次是 `/dev/video1`）上有了 `force_key_frame`。

**结果**（手机上是最终的包 `1.1.1+gitee8622c-0diting4`，三个补丁；脚本
`phone-s1-verify.sh`、`phone-qva-final2.sh`，日志在手机 `~/qva/` 和工作区
`liuqin-study/raw/vaenc-eval/`）：

| 请求关键帧（ffmpeg，H.264 High，720p，300 帧，CBR 2 Mbit/s） | 关键帧落在第几帧 | 带 SPS/PPS 的 IDR |
| --- | --- | --- |
| 只要第一个 | 0 | 1 |
| 每 30 帧 | 0、30、…、270 | 10 |
| 2 秒和 4 秒 | 0、60、120 | 3 |
| 每 3 秒（按表达式） | 0、90、180、270 | 4 |
| 每一帧 | 0 到 299 | 300 |

上游的测试原样跑：`api-smoke` 过；`ffmpeg-smoke.py` 9 个用例过（SSIM 0.994–0.998）；`async`
H.264 跑 20 遍、HEVC 跑 10 遍，没有一次失败。`rate-change`、码控对照、解码回归（两个驱动）、
并发、seek、截断流、74 条流的矩阵：和上午一个数不差。内核日志里没有 iris 的内容。

**第三个缺陷：请求的关键帧偶尔晚一帧（补丁 0003）。** 重启后第一次验证时 `async` 的 H.264
倒在“逐帧等结果的码流和排 8 帧的码流必须逐字节相同”上。抓下来看（`async-dump`，工作区
`liuqin-study/scripts/`）：两个**都是逐帧等结果**的会话，第 68 帧请求的 IDR 没出，成了一帧普通
的 P，第 69 帧才是带 SPS/PPS 的 IDR，之后两个流又逐字节相同。不带补丁的第一版驱动同样抓到
一次（第 17 帧请求，第 18 帧出）。所以它既不是我们的补丁引起的，也和排队深度无关。

- 比率：不等待时 5 次不同的会话，共约 4900 次请求（打补丁的 45 轮 1 次，不打补丁的 10 轮
  1 次，同一份实验二进制的对照组 189 轮 3 次），约千分之一；上游的 `async` 80 遍里因此败 3 遍。
- 内核侧查过：属性包和缓冲包走同一条命令队列、按序入队，写失败会打 `queue full`（没有），内核
  也不等固件确认属性。所以能做的只是在驱动里等一下。
- 试验：实验版驱动里请求之后、送缓冲之前等 1 毫秒（`QVA_KF_DELAY_US=1000`），500 轮
  （1 万次请求）0 次不同；同一份二进制把等待关掉，189 轮 3 次。
- 修法：0003，等 1 毫秒，并把 `async-dump` 收进包的测试里。之后累计 1.3 万次请求没有一次
  （按原来的比率应有 13 次）。这是缓解，不是对固件内部发生了什么的证明。
- 对使用的意义：即便晚一帧，流仍然是可解的（下一帧就是 IDR），所以它从来没让画面坏过，
  让的是“同一条流逐字节可重复”这种要求。内核给码流缓冲打着 `V4L2_BUF_FLAG_KEYFRAME`，
  以后要查固件有没有照做，可以看它。

**Chromium 的结论：这台手机上 GBM 分配不了 NV12。** 读 Chromium 158 的源码找到链路：来自内存
的帧要先装进一个 CPU 可写的 NV12 GPU 缓冲，这个缓冲由共享图像后端经 GBM 做；Wayland 下它只认
GBM 报“能扫描输出”的格式（`ui/gfx/linux/gbm_wrapper.cc` 的 `GetSupportedGbmFlags`，不用
minigbm 的那一支），Vulkan 和 Ozone 后端又都只接受 GBM 或客户端提供的缓冲。然后在手机上直接问
GBM（`gbm-probe`，工作区 `liuqin-study/scripts/`，对 1280×736 的 NV12 建缓冲并映射写入）：

| 格式和用途 | 主机的 Mesa 26.0.8 | snap 里的 Mesa 26.0.4 |
| --- | --- | --- |
| NV12，SCANOUT | 不支持，建不出 | 不支持，建不出 |
| NV12，LINEAR | 不支持，建不出 | 不支持，建不出 |
| NV12，LINEAR + RENDERING | 不支持，建不出 | 不支持，建不出 |
| XRGB8888，SCANOUT（对照） | 支持，建出并映射写入 | 支持，建出并映射写入 |

所以 `Unable to create a mappable shared image`，然后回退软编；换成 X11 也一样（那条路要的是
LINEAR）。Chromium 的 VA 编码器自己有一条不经过 GBM 的路（`CreateSurfacesForShmemEncoding`：
驱动分配 NV12 surface，CPU 拷进去，上游的 `api-smoke` 走的就是这种上传，能过），但适配层在
Linux 上固定选 GPU 缓冲，没有开关。要浏览器在这台手机上用硬件编码，得上游：Mesa 的 msm 驱动
支持经 GBM 分配 NV12（Wayland 下还得能扫描输出），或者 Chromium 的适配层在 GBM 做不出时改用
共享内存输入。

**另一个客户端：RustDesk，卡在 I420 上传**（当晚驱动补上了，见 12.8）。机主问能不能用
RustDesk 测编码。手机上没装它；
读的是它的 `hwcodec`（`rustdesk-org/hwcodec`）：Linux 上的硬件编码是 ffmpeg 的 `h264_vaapi`，
设备用默认的渲染节点，帧是 I420，经 `av_hwframe_transfer_data()` 送进 VA surface；
`async_depth=1`，`idr_interval` 和 `gop_size` 最大，低延迟，码控用 ffmpeg 的默认模式加码率，运行中
改 `bit_rate`。不装它也能验证这条路：用 ffmpeg 8.0.1 照这些参数编 `testsrc2`
（`phone-qva-rustdesk.sh`，工作区 `liuqin-study/scripts/`，输出在
`raw/vaenc-eval/rustdesk-2026-11-27/`）。

| | 驱动 | 上传 | 结果 |
| --- | --- | --- | --- |
| A | 默认（`msm`） | I420 | surface 建出来了，写不进去（`vaPutImage` 没实现）；然后 `No usable encoding entrypoint` |
| B | qcom | I420 | 建不出 surface：`surface pixel format does not match RT format`。libavutil 给 I420 帧建 surface 时把像素格式设成 I420，上游驱动只会建 NV12 的 |
| C | qcom | 先 `format=nv12` 再 `hwupload` | 能编，见下表 |

C 的数（其余参数和 RustDesk 一样，300 帧，两次运行）：

| 尺寸 | 帧率 | 实测码率 | 要的码率 |
| --- | --- | --- | --- |
| 1280×720 | 145、159 帧/秒 | 4127 kbit/s | 4000 |
| 1920×1080 | 107、122 帧/秒 | 7481 kbit/s | 6000 |
| 2340×1080（屏幕） | 84、84 帧/秒 | 9898 kbit/s | 8000 |

所以 RustDesk 配第四个补丁之前的驱动会留在软编。要它能用，三件事：驱动支持 I420 的 surface，送编码器之前
转成 NV12（第四个补丁，12.8）；RustDesk 的进程里有 `LIBVA_DRIVER_NAME=qcom`；手机上装 RustDesk。
RustDesk 在这台手机上能不能抓到屏幕（Wayland 下要经 portal）没试过。

**这对 0 节的路线意味着什么**：评估时把“浏览器里视频通话用上硬件编码”当作目标，S0 的结果
回答了它——驱动、内核、固件这一半都通了，卡在 Chromium 和 Mesa 之间。VA-API 编码器本身在这台
手机上是可用的，只是没有现成的浏览器客户端。

### 12.8 晚上：RustDesk 的路，第四个补丁

**补丁 0004：编码器收 I420 的 surface。**
`patches/0004-surfaces-take-I420-on-the-encoder-the-format-FFmpeg-u.patch`，包
`1.1.1+gitee8622c-0diting5`。12.7 末尾那个卡点的解法。

- **做法。** I420 的 surface 就是 NV12 的 surface 一直用的那块内存（两种格式总大小相同，分配不用
  动），按三个平面读：亮度之后是 U，U 之后是 V，各占一半的跨距、一半的行。`vaDeriveImage` 给出
  三个平面的图像，客户端原地写入，自己不做任何转换——比 NV12 那条路还省一次 CPU 转换。
  `vaGetImage`、`vaPutImage` 在 I420 的 surface 两侧都收 I420 和 NV12 的图像。编码器在本来就要
  拷一帧的那一步（`copy_surface`）里把色度交织成 NV12。
- **只对编码开放。** `vaQuerySurfaceAttributes` 只给编码的 config 列出 I420；解码和 VPP 还是
  NV12/P010；I420 的 surface 不能导出。
- **测试 `tests/encoder/i420-surface`**（收进包里）：
  1. 编码的 config 列出了 I420。
  2. 图像读写：同一帧经 `vaDeriveImage` 写入，用 `vaGetImage` 按 I420、按 NV12 读回；再用
     `vaPutImage` 从 I420 图像、从 NV12 图像写入，读回。每个样本都要在原处，U、V 不许对调
     （色度让每个样本上 U、V 都不同，调换会暴露）；导出被拒。
  3. 同一批 96 帧（async.cpp 的会话：640×480，CQP，QP 24/28，每 17 帧一个 IDR）走两条路进
     编码器：A 是一直能用的“`vaPutImage` 把 I420 图像放到 NV12 surface 上”，B 是 libavutil 的
     做法“直接写进 I420 的 surface”。两条路的码流必须逐字节相同。

**结果**（手机上 `1.1.1+gitee8622c-0diting5`；脚本 `phone-qva-i420.sh`、`phone-qva-final2.sh`，工作区
`liuqin-study/scripts/`；日志 `liuqin-study/raw/vaenc-eval/rustdesk-2026-11-27/`）：

| `i420-surface` | 结果 |
| --- | --- |
| H.264 | 三步都过；两条路一个码流，1,244,256 字节 |
| HEVC | 三步都过；两条路一个码流，2,268,009 字节 |

ffmpeg 8.0.1，RustDesk 给 `h264_vaapi` 的参数，`testsrc2`，300 帧，I420 直接上传（12.7 里败在建
surface 的那条命令）：

| 尺寸 | 帧率 | 码率（要的） | 和“CPU 先转 NV12 再上传”的码流比 | 解回来对源的 PSNR |
| --- | --- | --- | --- | --- |
| 1280×720 | 169 帧/秒 | 4127 kbit/s（4000） | 逐字节相同 | 45.4 dB |
| 1920×1080 | 120 帧/秒 | 7481 kbit/s（6000） | 逐字节相同 | 44.6 dB |
| 2340×1080（屏幕） | 96 帧/秒 | 9898 kbit/s（8000） | 逐字节相同 | 44.4 dB |

“逐字节相同”是这里最要紧的一个数：同一个源，CPU 先转 NV12 再上传（swscale 转换）和 I420 直接
上传（驱动交织），编码器收到的样本必须一模一样，码流才会相同。

整套回归（`phone-qva-final2.sh`）和下午 `0diting4` 的那份日志逐行对比：除了版本号和指针地址，行为
完全相同——请求关键帧落在指定的帧上；上游测试原样全过（`api-smoke`；`async` H.264 20 遍、HEVC 10 遍
零失败；`ffmpeg-smoke.py` 9 个用例）；`async-dump` H.264 100 轮、HEVC 30 轮全同；`rate-change` 和
码控对照十个数一个不差（后者那一步脚本要的工作目录 `~/qva/s0` 不在了，单独补跑的）；解码回归（两个
驱动）相同，包括 10-bit 的 P010；74 条流的矩阵零失败；内核日志零行。

**还差的**：

- `rate-change.cpp:61` 有一处编译警告（花括号初始化里的类型窄化，补丁 0002 的测试），报上游前清掉。

**RustDesk 装上实测**（机主要求，23:05 起）。官方 `rustdesk-1.5.3-aarch64.deb`，只新装了这一个包；
服务带 `LIBVA_DRIVER_NAME=qcom`（drop-in），Mac 上的 RustDesk 1.4.6 当控制端，IP 直连。

- **编码器这一半是通的**：RustDesk 自己的探测（`--check-hwcodec-config`）报
  `Encoder h264_vaapi created successfully`、`test passed on attempt 1`，VA-API 的 H.264/HEVC 解码器
  也过；每次会话的协商都是 `used preference: Auto, encoder: H264`。第四个补丁之前它连编码器都打不开。
- **画面出不来**，一帧都没进编码器。卡在手机的屏幕共享链路上，和编码器无关：
  1. 屏幕选择器 `slurp`（1.6.0）一起动就段错误，portal 回“用户取消”，屏幕上从没出现过确认框；
  2. 绕过选择器之后，RustDesk 的 `pipewiresrc` 一接上，`xdg-desktop-portal-wlr`（0.8.1）就在
     `xdpw: unable to find format: 875713112`（XR24）之后段错误，systemd 重启它（那晚七次）；
     RustDesk 的流随后被会话管理器接到摄像头上，30 秒后 Mac 超时断开；
  3. `/dev/uinput` 不存在，远程键鼠注入不了。
- 过程、证据和 RustDesk 的几个“惯例”（IP 直连默认关、空闲后第一次连接会被重置等）记在
  `ubuntu-diting/docs/KNOWN_ISSUES.md` 的“Screen sharing through the desktop portal”一节。
- 测完手机已恢复：免选择器的配置、调试日志、临时密码、IP 直连都撤了；RustDesk 留着，开机自启，
  没有固定密码。我弄崩过一次主 portal（手工调用漏了参数，断了 35 秒，已恢复）。
