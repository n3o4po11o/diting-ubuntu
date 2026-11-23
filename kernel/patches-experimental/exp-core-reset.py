#!/usr/bin/env python3
"""EXPERIMENT: add the video core reset to the SM8450 iris node, alone.

Upstream sm8250 (the same VPU2 core) resets "bus" and "core" at power-on:
    resets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>,
             <&videocc VIDEO_CC_MVS0C_CLK_ARES>;
    reset-names = "bus", "core";
and iris_clk_reset_table_vpu2 = { "bus", "core" }. The local sm8450 port
(0078/0079) copied the SM8550 (VPU3) single "bus" reset instead.

Usage: python3 exp-core-reset.py <kernel-src-dir>
"""
import os, sys

KS = sys.argv[1]
DTS = os.path.join(KS, "arch/arm64/boot/dts/qcom/sm8450.dtsi")
PLAT = os.path.join(KS, "drivers/media/platform/qcom/iris/iris_platform_vpu2.c")


def edit(path, old, new, tag):
    s = open(path).read()
    if new in s:
        print("SKIP (applied):", tag)
        return
    assert s.count(old) == 1, "MISS %s (%d)" % (tag, s.count(old))
    open(path, "w").write(s.replace(old, new, 1))
    print("OK:", tag)


edit(DTS,
     "#include <dt-bindings/reset/qcom,sm8450-gpucc.h>\n",
     "#include <dt-bindings/reset/qcom,sm8450-gpucc.h>\n"
     "#include <dt-bindings/reset/qcom,sm8350-videocc.h>\n",
     "DT: videocc reset header")
edit(DTS,
     '\t\t\tresets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>;\n'
     '\t\t\treset-names = "bus";\n',
     '\t\t\tresets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>,\n'
     '\t\t\t\t <&videocc VIDEO_CC_MVS0C_CLK_ARES>;\n'
     '\t\t\treset-names = "bus", "core";\n',
     "DT: iris core reset")
edit(PLAT,
     'static const char * const sm8450_clk_reset_table[] = { "bus" };',
     'static const char * const sm8450_clk_reset_table[] = { "bus", "core" };',
     "platform data: bus+core resets")
