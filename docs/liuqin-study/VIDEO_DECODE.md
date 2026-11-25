# 视频硬解：diting 现状实测，与 liuqin 项目对照

> 实测日期 2026-11-26。手机：`7.2.10-diting #52`（包 `linux-image-7.2.10-diting 7.2.10-52`），
> Ubuntu 26.04.1。原始输出：`/Users/f/work/redmi-k50ultra/liuqin-study/raw/probe-video*.txt`
> （工作区，不在仓库内）。测试脚本：同目录 `../scripts/probe-video*.sh`。

## 1. 结论

1. **我们的系统能硬解 H.264，而且不止 H.264**：iris 解码器（固件 `vpu20_4v.mbn`）列出
   H.264、HEVC、VP9 三种格式。**8-bit H.264 / HEVC / VP9 在 VA-API 与 V4L2 两条路径上都与软解
   逐帧逐字节一致**（1080p 和 4K 都测了）。**HEVC Main10（10-bit）经 V4L2（GStreamer）同样
   逐字节一致**。AV1 不支持。
2. **对方只有 H.264**。liuqin 的 README 明确写着“暂不支持：其他格式的视频硬解、浏览器视频硬解、
   硬件视频编码”。它的内核在 `2cd5a6f8ef67`（"arm64: add Xiaomi Pad 6 Pro support"）里自己加了
   `qcom,sm8450-iris` 的平台数据，用户态没有 VA-API 包。所以这一项上我们领先，没有可取之处，
   只有下面 §4 的两点值得参考。
3. 实测暴露出我们自己的两个问题（之前文档写的是“未测试”）：
   - **VA-API 路径解 10-bit 输出是坏画面**（`libva-v4l2-stateful` 只实现了 NV12 下载，把 P010
     缓冲区当成 NV12 读，画面被横向压扁、颜色错乱，已截图确认）。
   - **GStreamer 的 `v4l2vp9dec` 解 VP9 会插入坏帧并丢帧**，而同一固件经 VA-API 解 VP9 是精确的。
     这意味着用 GStreamer 播放器放 VP9 会花屏，浏览器（走 VA-API）不受影响。

## 2. 能力矩阵（手机实测）

解码节点 `/dev/video0`："Iris Decoder (plat:aa00000.video-codec:dec)"。`VIDIOC_ENUM_FMT`：
`H264`、`HEVC`、`VP90`；三种格式都是 Stepwise 128×128 – 8192×8192。

| 控件 | 值 |
| --- | --- |
| `h264_profile` / `h264_level` | High（菜单到 17）/ 6.1 |
| `hevc_profile` / `hevc_level` / `hevc_tier` | Main（菜单 0–2）/ 6.1 / High |
| `vp9_profile` / `vp9_level` | 0（菜单 0–2）/ 6 |
| `av1_profile` | 菜单存在，max = 0，没有 AV1 格式 |
| `display_delay` / `display_delay_enable` | 0 / 0 |

VA-API（`libva-v4l2-stateful 0.1.0+git6447ebb-0diting2`，驱动 `msm_drv_video.so`，
"VA-API V4L2 Stateful driver (CIX Sky1, Qualcomm iris)"）：`VAProfileH264ConstrainedBaseline`、
`H264Main`、`H264High`、`HEVCMain`、`HEVCMain10`、`VP9Profile0`、`VP9Profile2`，全部只有
`VAEntrypointVLD`（只解码，没有编码入口点）。

## 3. 正确性

测试流由 `ffmpeg -f lavfi -i testsrc2` 现场生成。md5 是 `framemd5`（NV12）的摘要。

### 3.1 ffmpeg 三条路径（`probe-video.txt`）

| 流 | 软解 | VA-API（hwaccel） | V4L2 m2m |
| --- | --- | --- | --- |
| H.264 High 1080p，150 帧 | `b608b8a5aed3` | 相同 | 相同 |
| H.264 High 4K，150 帧 | `ef8a423a252d` | 相同 | 相同 |
| HEVC Main 1080p，150 帧 | `d0e43c030780` | 相同 | 相同 |
| HEVC Main10 4K | — | 输出坏画面（见 §5.1） | 起不来：`capture buffer[0] initialization (Invalid argument)`（ffmpeg 的 m2m 封装不支持 P010 采集） |
| VP9 Profile 0 1080p，150 帧 | `2f99300cdf9b` | 相同 | 报错 `capture: driver decode error`（ffmpeg 不发 VP9 的逐帧控制） |
| VP9 Profile 2 10-bit | — | 有帧输出，未做画面核对 | 同 HEVC 10-bit |

### 3.2 GStreamer 的 V4L2 解码器对软解（`probe-video13.txt`，`probe-video14.txt`）

两侧都经同一个 `videoconvert` 转成 NV12 再逐字节比较，每条流 90 帧。

| 流 | 解码器 | 结果 |
| --- | --- | --- |
| H.264 High 1080p | `v4l2h264dec` | 90/90 帧完全一致 |
| HEVC Main 1080p | `v4l2h265dec` | 90/90 帧完全一致 |
| HEVC Main10 1080p | `v4l2h265dec` | 90/90 帧完全一致 |
| VP9 Profile 0 1080p | `v4l2vp9dec` | **89 帧，全部不一致** |
| VP9 Profile 2 10-bit 1080p | `v4l2vp9dec` | **89 帧，全部不一致** |

VP9 的问题用“每帧唯一灰阶”的探针流（320×240，第 k 帧亮度 = 16 + 2k）看得更清楚
（`probe-video14.txt`）：

```
软解  前 12 帧: [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]   共 90 帧
硬解  前 12 帧: [9, 0, 64, 11, 12, 0, 64, 14, 15, 16, 0, 64]     共 113 帧
VA-API        : 与软解 90/90 一致
```

硬解多出 23 帧，每 3 帧里有一组“亮度 0”和“亮度 64、色度 26”的帧，顶替了第 10、13、16… 帧。
这是 libvpx 在实时模式下插入的不可见 alt-ref 帧（对应的可见帧靠 `show_existing_frame` 引用）
没有被正确处理：固件对这些隐藏帧返回空缓冲区，`libva-v4l2-stateful` 会丢弃它们（KNOWN_ISSUES
里为 Chromium 写的处理），GStreamer 的 `v4l2vp9dec` 把它们当成帧吐了出来。

`decodebin` 的自动选择：`v4l2h264dec` 的 rank 是 primary + 1（257），`decodebin` 实际选中的就是
`v4l2h264dec0`（`GST_DEBUG=3` 可见）。所以 GStreamer 应用放 H.264/HEVC 走硬解且正确，放 VP9
会花屏。

### 3.3 缓冲区布局（做逐字节比较时必须知道）

V4L2 输出缓冲区按编码高度分配：1080p 的亮度平面占 1088 行，但**色度平面从 1920×1080 处开始**，
不是 1088 行之后。我最初按 1088 行之后去取色度，得出“全部不一致”的错误结论；改正后
H.264/HEVC 90/90 一致。P010（10-bit）同理，帧大小是 1920×1088×3 字节。

## 4. 性能（`probe-video.txt`，`probe-video3.txt`）

| 流 | VA-API 硬解 | ffmpeg 软解 |
| --- | --- | --- |
| 4K HEVC Main10，150 帧 | CPU 0.7–0.9 s，墙钟 1.09–1.24 s（约 125 fps） | CPU 22–23 s，墙钟 3.5–3.7 s（8 核，约 41 fps） |
| 1080p H.264，150 帧 | CPU 0.16–0.2 s，墙钟 0.38–0.40 s | 未单测 |

同一序列重复两轮、空闲 20 s 和 40 s 后再跑，结果一致。

## 5. 实测发现的问题

### 5.1 VA-API 解 10-bit 是坏画面

- `-hwaccel_output_format p010le`：`Failed to transfer data to output frame: -38`（ENOSYS）。
  驱动没有实现 P010 下载。
- `-hwaccel_output_format nv12`：能出 120 帧，但内容是错的。同一帧（HEVC Main10 第 10 帧）
  三路截图在 `liuqin-study/raw/frames/`：`hevc10-sw.png` 是正常的彩条，`hevc10-va.png` 是
  被横向压成一半、颜色错乱的图，即 P010 数据被当成 NV12 读。
- 与软件的 10→8 bit 转换相比 PSNR 约 7 dB（`probe-video8.txt`）。

KNOWN_ISSUES 原文是“advertised but only NV12 output is implemented: untested and expected to
fail”，现在是测过了：**确认失败**。受影响的是任何经 VA-API 播放 10-bit HEVC/VP9 的程序
（Firefox、Chromium）。规避办法是让浏览器不要选 10-bit 的 profile，或者给
`libva-v4l2-stateful` 加 P010 支持。

### 5.2 GStreamer 的 VP9 解码不可用

见 §3.2。H.264 与 HEVC（含 10-bit）在 GStreamer 下是正确的。

### 5.3 一次未复现的 32 秒停顿

第一轮测试里 1080p H.264 的 VA-API 解码墙钟时间是 32.17 s（CPU 只用了 0.4 s），同样的命令
之后跑了 5 次都是 0.4 s，包括空闲 20 s / 40 s 之后。没有查到原因，先记在这里。

### 5.4 已有的已知限制（未变）

- 没有硬件编码：r36 起不注册编码节点（KNOWN_ISSUES “Video encoder resets the phone”）。
- 没有 AV1。
- 用过 iris 之后重启可能卡在 `systemd-shutdown`（KNOWN_ISSUES）。

## 6. 应用层现状

| 应用 | 状态 | 依据 |
| --- | --- | --- |
| Firefox 160.0.1（deb 包） | 已配置强制硬件解码 | `/usr/lib/firefox/defaults/pref/firefox-vaapi.js`：`pref("media.hardware-video-decoding.force-enabled", true)` |
| Chromium（snap） | 经 `diting-chromium-vaapi` 用户服务装载驱动 | KNOWN_ISSUES “Browser video decoding” |
| GStreamer 1.28.2 | `v4l2h264dec` / `v4l2h265dec` / `v4l2vp9dec`，rank 257；`va` 插件（`libgstva.so`）存在但没有注册出元素（`no element "vah265dec"`） | `gst-inspect-1.0` |
| ffmpeg 8.0.1 | 有 `h264_v4l2m2m` / `hevc_v4l2m2m` / `vp9_v4l2m2m` 解码器与 `h264_vaapi` / `hevc_vaapi` 编码器 | `ffmpeg -decoders` |

## 7. 与 liuqin 的对照

| | liuqin | diting |
| --- | --- | --- |
| 内核 | 6.17-rc1 基础。`2cd5a6f8ef67`（"arm64: add Xiaomi Pad 6 Pro support"，58 个文件）在 `iris_platform_gen2.c` 里加 `sm8450_data` 和 `platform_inst_cap_sm8450`，`iris_probe.c` 加 `qcom,sm8450-iris`，`sm8450.dtsi` 加 `video-codec@aa00000`；板级只写 `&iris { status = "okay"; };` | 7.2.10，补丁 0077–0084（绑定、平台数据、Gen2 固件解码修复、不注册编码器、解码序输出、时间戳越界） |
| 平台数据 | `fwname = "qcom/vpu/vpu20_4v.mbn"`，Gen2 HFI，`vpu_ops = &iris_vpu3_ops`，复位 `bus` + `core`，继承 SM8550 的编解码 / profile / 电平表和缓冲表；能力上限 8192×4320，`max_session_count = 16`，`num_vpp_pipe = 4` | 同一固件；`iris_vpu2_ops`，只复位 `bus`，SM8250 的带宽表，去掉 `PARTIAL_DATA` 缓冲 |
| OPP | 240 / 338 / 366 / 444 MHz | 更高 |
| 文档里的格式 | 只有 H.264；"暂不支持：其他格式的视频硬解、浏览器视频硬解、硬件视频编码" | H.264、HEVC（含 Main10）、VP9；浏览器硬解 |
| 用户态 | 没有 VA-API；镜像带 `gstreamer1.0-libav`（软解）、plugins-bad（`h264parse`）。H.264 硬解只能经 GStreamer 的 `v4l2h264dec` | `libva-v4l2-stateful`，浏览器硬解 |

对方为什么只有 H.264：它的能力表引用的是 SM8550 的表，那些表里有哪些格式我没有核对；README 的
表述是产品层面的“可用”，没有说明另外两种格式是不能解还是没有做。这是我没有查清的一点。

对方这边只有 `a90359262dac`（"media: iris: Fix power-off ordering to disable power domain after
clocks"，带 `Cc: stable`）值得一看，它可能与“用过 iris 后关机卡住”有关；7.2.10 的 iris 电源
代码已搬到 `iris_vpu3x.c` / `iris_vpu4x.c`，我没有核对到对应位置。

## 8. 建议的下一步

1. 给 `libva-v4l2-stateful` 加 P010 下载（或在驱动里做 10→8 bit 的正确转换），否则浏览器放
   10-bit 视频会花屏。
2. 查 GStreamer `v4l2vp9dec` 与 iris 的空缓冲区处理（`gst_v4l2_buffer_pool_process` 对
   `bytesused == 0` 的处理）。
3. 核对 `a90359262dac` 与我们的电源关闭路径。
