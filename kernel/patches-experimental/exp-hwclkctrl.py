#!/usr/bin/env python3
"""EXPERIMENT (never committed as is): hardware clock control for the video
core clock sources, what downstream calls HW_CLK_CTRL_MODE.

Downstream videocc-waipio.c sets CFG_HW_CLK_CTRL_MASK (BIT(20), clk-rcg2.c)
in the CFG register of video_cc_mvs0_clk_src / video_cc_mvs1_clk_src, so the
VPU hardware may enable its own core clock (needed by hardware controlled
intra-frame power collapse). Mainline has no such flag.

Usage:
    python3 exp-hwclkctrl.py <kernel-src-dir>

Sets the bit once after qcom_cc_probe(); clk_rcg2_configure() only rewrites
the src/mode/div fields, so the bit persists across rate changes.
"""
import sys, os

p = os.path.join(sys.argv[1], "drivers/clk/qcom/videocc-sm8450.c")
s = open(p).read()
if "CFG_HW_CLK_CTRL" in s:
    print("SKIP (already applied)")
    sys.exit(0)

T = "\t"
old = (T + "return qcom_cc_probe(pdev, &video_cc_sm8450_desc);\n" + "}\n")
new = (
    T + "ret = qcom_cc_probe(pdev, &video_cc_sm8450_desc);\n" +
    T + "if (ret)\n" +
    T + T + "return ret;\n" +
    "\n" +
    T + "/*\n" +
    T + " * EXPERIMENT: downstream HW_CLK_CTRL_MODE (CFG_HW_CLK_CTRL_MASK = BIT(20))\n" +
    T + " * lets the VPU hardware enable its own core clock, which the hardware\n" +
    T + " * controlled intra-frame power collapse relies on.\n" +
    T + " */\n" +
    T + "regmap_update_bits(dev_get_regmap(&pdev->dev, NULL), 0x8004, BIT(20), BIT(20));\n" +
    T + "regmap_update_bits(dev_get_regmap(&pdev->dev, NULL), 0x801c, BIT(20), BIT(20));\n" +
    "\n" +
    T + "return 0;\n" +
    "}\n"
)
assert s.count(old) == 1, "probe anchor count %d" % s.count(old)
s = s.replace(old, new, 1)

old2 = "static int video_cc_sm8450_probe(struct platform_device *pdev)\n{\n"
assert s.count(old2) == 1, "probe signature count %d" % s.count(old2)
s = s.replace(old2, old2 + T + "int ret;\n\n", 1)

old3 = "#include <linux/regmap.h>\n"
assert s.count(old3) == 1
s = s.replace(old3, old3 + "#include <linux/bits.h>\n", 1)

open(p, "w").write(s)
print("OK: videocc-sm8450 probe sets CFG_HW_CLK_CTRL on mvs0 (0x8004) and mvs1 (0x801c)")
