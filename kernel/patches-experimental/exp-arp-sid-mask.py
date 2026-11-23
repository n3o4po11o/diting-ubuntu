#!/usr/bin/env python3
"""EXPERIMENT (never committed as is): route the VPU "non-pixel" master SID
(0x2184) through the iris context bank at runtime.

Downstream maps the encoder ARP buffer through venus_sec_non_pixel (SID
0x2184). The mainline iris node only lists SIDs 0x2180 and 0x2187. Adding
0x2184 to the DT with the downstream form (<0x2184 0x400>) hangs the boot,
and writing that form at runtime aborts: measured on hardware, the apps
SMMU only accepts a stream match entry whose ID has 1s at every masked
bit position (bit 10 is exempt, every entry has it as don't care), i.e.
the ID must be the TOP of the range its mask covers:

    accepted:  (0x2187, 0x404) -> 0x2183..0x2187     (0x2184, 0x400)
               (0x2187, 0x407) -> 0x2184..0x2187
    rejected:  (0x2184, 0x400), (0x2180, 0x404), (0x2180, 0x420),
               (0x2184, 0x406), ...  synchronous external abort on the write

So the idle 0x2187 entry (the pixel stream, same context bank) is rewritten
to (0x2187, 0x407), which covers the pixel stream and 0x2184 alike. The
firmware's live entry (0x2180) is never touched.

RESULT on hardware: the entry is accepted and 0x2184 is translated, but the
encoder still resets the SoC on frame 0. Keep for the record only.

Requires the ARP mapping part of exp-arp-reset.py (ARP at 0x01000000).
Usage: python3 exp-arp-sid-mask.py <kernel-src-dir>
"""
import sys, os

p = os.path.join(sys.argv[1], "drivers/media/platform/qcom/iris/iris_buffer.c")
s = open(p).read()
if "iris_arp_sid_alias" in s:
    print("SKIP (already applied)")
    sys.exit(0)

T = "\t"


def edit(old, new, tag):
    global s
    old = old.replace("${T}", "\t")
    new = new.replace("${T}", "\t")
    assert s.count(old) == 1, "MISS %s (%d)" % (tag, s.count(old))
    s = s.replace(old, new, 1)
    print("OK:", tag)


edit("#include <linux/iommu.h>\n",
     "#include <linux/device/bus.h>\n"
     "#include <linux/iommu.h>\n"
     "#include <linux/io.h>\n"
     "#include <linux/moduleparam.h>\n"
     "#include <linux/pm_runtime.h>\n",
     "includes")

edit("#define IRIS_ARP_IOVA\t\t0x01000000\n",
     "#define IRIS_ARP_IOVA\t\t0x01000000\n"
     "\n"
     "/* EXPERIMENT: route the VPU non-pixel master SID through the iris domain */\n"
     "static bool arp_sid_alias = true;\n"
     "module_param(arp_sid_alias, bool, 0644);\n"
     "\n"
     "#define IRIS_SMMU_BASE\t\t0x15000000ul\n"
     "#define IRIS_SMMU_SMR(n)\t\t(0x800 + (n) * 4)\n"
     "#define IRIS_SMR_ID\t\t\tGENMASK(14, 0)\n"
     "#define IRIS_SMR_MASK\t\tGENMASK(30, 16)\n"
     "\n"
     "static int iris_arp_sid_alias(struct device *dev)\n"
     "{\n"
     "${T}struct device *smmu_dev;\n"
     "${T}void __iomem *base;\n"
     "${T}u32 reg, rd;\n"
     "${T}int idx, ret;\n"
     "${T}const u32 want = 0x84072187; /* VALID | mask 0x407 | ID 0x2187 */\n"
     "\n"
     "${T}if (!arp_sid_alias)\n"
     "${T}${T}return 0;\n"
     "\n"
     "${T}smmu_dev = bus_find_device_by_name(&platform_bus_type, NULL,\n"
     "${T}${T}${T}${T}${T}${T} ${T}  \"15000000.iommu\");\n"
     "${T}if (!smmu_dev)\n"
     "${T}${T}return dev_err_probe(dev, -ENODEV, \"apps SMMU device not found\\n\");\n"
     "\n"
     "${T}ret = pm_runtime_get_sync(smmu_dev);\n"
     "${T}if (ret < 0 && ret != -EACCES) {\n"
     "${T}${T}put_device(smmu_dev);\n"
     "${T}${T}return ret;\n"
     "${T}}\n"
     "\n"
     "${T}ret = -ENODEV;\n"
     "${T}base = ioremap(IRIS_SMMU_BASE, 0x10000);\n"
     "${T}if (!base) {\n"
     "${T}${T}ret = -ENOMEM;\n"
     "${T}${T}goto out;\n"
     "${T}}\n"
     "\n"
     "${T}for (idx = 0; idx < 128; idx++) {\n"
     "${T}${T}reg = readl_relaxed(base + IRIS_SMMU_SMR(idx));\n"
     "${T}${T}if ((reg & IRIS_SMR_ID) == 0x2187)\n"
     "${T}${T}${T}goto found;\n"
     "${T}}\n"
     "${T}dev_err(dev, \"apps SMMU: no stream match entry for SID 0x2187\\n\");\n"
     "${T}goto unmap;\n"
     "\n"
     "found:\n"
     "${T}/* the SMMU driver rewrites its entries after runtime suspend */\n"
     "${T}if (reg == want) {\n"
     "${T}${T}ret = 0;\n"
     "${T}${T}goto unmap;\n"
     "${T}}\n"
     "${T}if ((reg & IRIS_SMR_MASK) != FIELD_PREP(IRIS_SMR_MASK, 0x400)) {\n"
     "${T}${T}dev_err(dev, \"apps SMMU SMR[%d] = %#x: unexpected mask\\n\", idx, reg);\n"
     "${T}${T}goto unmap;\n"
     "${T}}\n"
     "${T}writel_relaxed(want, base + IRIS_SMMU_SMR(idx));\n"
     "${T}rd = readl_relaxed(base + IRIS_SMMU_SMR(idx));\n"
     "${T}dev_info(dev, \"apps SMMU SMR[%d]: %#x -> %#x (SID 0x2184..0x2187 share the iris context bank)\\n\",\n"
     "${T}${T} idx, reg, rd);\n"
     "${T}ret = (rd == want) ? 0 : -EIO;\n"
     "\n"
     "unmap:\n"
     "${T}iounmap(base);\n"
     "out:\n"
     "${T}pm_runtime_put(smmu_dev);\n"
     "${T}put_device(smmu_dev);\n"
     "${T}return ret;\n"
     "}\n",
     "SID alias helper")

edit("${T}struct page *page = alloc_pages(GFP_KERNEL | __GFP_ZERO, order);\n" +
     "${T}int ret;\n" +
     "\n" +
     "${T}if (!page)\n" +
     "${T}${T}return -ENOMEM;\n",
     "${T}struct page *page = alloc_pages(GFP_KERNEL | __GFP_ZERO, order);\n" +
     "${T}int ret;\n" +
     "\n" +
     "${T}if (!page)\n" +
     "${T}${T}return -ENOMEM;\n" +
     "\n" +
     "${T}ret = iris_arp_sid_alias(core->dev);\n" +
     "${T}if (ret)\n" +
     "${T}${T}goto err_sid;\n",
     "call alias from ARP alloc")

edit("${T}ret = iommu_map(dom, IRIS_ARP_IOVA, page_to_phys(page),\n" +
     "${T}${T}${T}  PAGE_ALIGN(buffer->buffer_size),\n" +
     "${T}${T}${T}  IOMMU_READ | IOMMU_WRITE, GFP_KERNEL);\n" +
     "${T}if (ret) {\n" +
     "${T}${T}__free_pages(page, order);\n" +
     "${T}${T}return ret;\n" +
     "${T}}\n",
     "${T}ret = iommu_map(dom, IRIS_ARP_IOVA, page_to_phys(page),\n" +
     "${T}${T}${T}  PAGE_ALIGN(buffer->buffer_size),\n" +
     "${T}${T}${T}  IOMMU_READ | IOMMU_WRITE, GFP_KERNEL);\n" +
     "err_sid:\n" +
     "${T}if (ret) {\n" +
     "${T}${T}__free_pages(page, order);\n" +
     "${T}${T}return ret;\n" +
     "${T}}\n",
     "error path")

open(p, "w").write(s)
print("experiment applied")
