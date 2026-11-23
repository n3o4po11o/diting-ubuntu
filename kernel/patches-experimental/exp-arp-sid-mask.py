#!/usr/bin/env python3
"""EXPERIMENT (never committed as is): make the VPU "non-pixel" master SID
reachable for the iris domain at runtime.

Downstream routes the encoder ARP buffer through venus_sec_non_pixel, i.e.
the hardware fetches the register programming stream with SID 0x2184. The
mainline iris node only lists SIDs 0x2180 and 0x2187, so that fetch has no
translation. Listing 0x2184 in the DT hangs the boot at the apps SMMU probe
(reproduced twice, mechanism unknown), so this is done from the driver at the
first encoder session instead: widen the mask of the existing 0x2180 stream
match entry to cover 0x2180-0x21ff. One MMIO write, the context bank is not
touched. Controlled by the module parameter arp_sid_alias (default on).

Requires exp-arp-reset.py's ARP mapping part (ARP at 0x01000000) to be applied.
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
     "static int iris_arp_sid_alias(struct device *dev)\n"
     "{\n"
     "${T}struct device *smmu_dev;\n"
     "${T}void __iomem *base;\n"
     "${T}u32 reg, rd;\n"
     "${T}int idx, stride, ret;\n"
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
     "${T}base = ioremap(0x15000000, 0x10000);\n"
     "${T}if (!base) {\n"
     "${T}${T}ret = -ENOMEM;\n"
     "${T}${T}goto out;\n"
     "${T}}\n"
     "\n"
     "${T}/* GR0 SMRn at 0x800: ID[14:0], MASK[30:16] (+VALID[31] without EXIDS) */\n"
     "${T}for (stride = 4; stride <= 16; stride += 12) {\n"
     "${T}${T}for (idx = 0; idx < 128; idx++) {\n"
     "${T}${T}${T}reg = readl_relaxed(base + 0x800 + idx * stride);\n"
     "${T}${T}${T}if ((reg & 0x7fff) == 0x2180 &&\n"
     "${T}${T}${T}    (((reg >> 16) & 0x7fff) == 0x400 ||\n"
     "${T}${T}${T}${T} ((reg >> 16) & 0x7fff) == 0x47f))\n"
     "${T}${T}${T}${T}goto found;\n"
     "${T}${T}}\n"
     "${T}}\n"
     "${T}dev_err(dev, \"apps SMMU: no stream match entry for SID 0x2180\\n\");\n"
     "${T}goto unmap;\n"
     "\n"
     "found:\n"
     "${T}/* the SMMU driver rewrites its entries after runtime suspend */\n"
     "${T}if (((reg >> 16) & 0x7fff) == 0x47f) {\n"
     "${T}${T}ret = 0;\n"
     "${T}${T}goto unmap;\n"
     "${T}}\n"
     "${T}rd = (reg & ~GENMASK(30, 16)) | (0x47f << 16);\n"
     "${T}writel_relaxed(rd, base + 0x800 + idx * stride);\n"
     "${T}rd = readl_relaxed(base + 0x800 + idx * stride);\n"
     "${T}dev_info(dev, \"apps SMMU SMR[%d]: %#x -> %#x (SID 0x2180-0x21ff share the iris context bank)\\n\",\n"
     "${T}${T} idx, reg, rd);\n"
     "${T}ret = (rd == ((reg & ~GENMASK(30, 16)) | (0x47f << 16))) ? 0 : -EIO;\n"
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
