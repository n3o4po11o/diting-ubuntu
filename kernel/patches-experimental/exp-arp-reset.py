#!/usr/bin/env python3
"""EXPERIMENT (never committed as is): align the SM8450 iris node with the two
things the working vpu2 configurations (downstream waipio, upstream sm8250)
do differently.

  A. ARP buffer through the non-pixel context bank. Downstream maps the encoder
     ARP buffer (the register programming stream the VPP executes) through
     venus_sec_non_pixel (SID 0x2184, IOVA pool 0x01000000..0x25800000) even
     for non-secure sessions; nothing else uses that bank. The mainline node
     only maps SIDs 0x2180/0x2187 and allocates ARP in the normal pool.
     -> DT: add SID 0x2184 to the iris node
        !!! LISTING SID 0x2184 IN THE IRIS NODE HANGS THE BOOT at the apps SMMU
        !!! probe (reproduced 2/2 on 2026-11-23, mechanism unknown). The edit is
        !!! skipped unless ARP_SID_DT=I-know-it-hangs-boot is set. Use
        !!! exp-arp-sid-mask.py instead, which widens the existing stream match
        !!! entry at the first encoder session.
     -> driver: map the ARP buffer at a fixed IOVA in the non-pixel pool

  B. Core reset. Upstream sm8250 (same vpu2 core) resets "bus" and "core";
     the local sm8450 data only has "bus".
     -> DT: add <&videocc VIDEO_CC_MVS0C_CLK_ARES> as "core"
     -> platform data: { "bus", "core" }

Usage: python3 exp-arp-reset.py <kernel-src-dir>
"""
import sys, os

KS = sys.argv[1]
T = "\t"


def edit(path, old, new, tag):
    old = old.replace("${T}", "\t")
    new = new.replace("${T}", "\t")
    s = open(path).read()
    if new in s:
        print("SKIP (applied):", tag)
        return
    assert s.count(old) == 1, "MISS %s (%d)" % (tag, s.count(old))
    open(path, "w").write(s.replace(old, new, 1))
    print("OK:", tag)


def replace_span(path, start, end, new, tag):
    """Replace the text from `start` (inclusive) through `end` (inclusive)."""
    start = start.replace("${T}", "\t")
    end = end.replace("${T}", "\t")
    new = new.replace("${T}", "\t")
    s = open(path).read()
    if new in s:
        print("SKIP (applied):", tag)
        return
    assert s.count(start) == 1, "MISS start %s (%d)" % (tag, s.count(start))
    i = s.index(start)
    j = s.index(end, i) + len(end)
    open(path, "w").write(s[:i] + new + s[j:])
    print("OK:", tag)


DTS = os.path.join(KS, "arch/arm64/boot/dts/qcom/sm8450.dtsi")
IRIS = os.path.join(KS, "drivers/media/platform/qcom/iris")

# ---------------------------------------------------------------- DT --------
edit(DTS,
     "#include <dt-bindings/reset/qcom,sm8450-gpucc.h>\n",
     "#include <dt-bindings/reset/qcom,sm8450-gpucc.h>\n"
     "#include <dt-bindings/reset/qcom,sm8350-videocc.h>\n",
     "DT: videocc reset header")

edit(DTS,
     "${T}${T}${T}resets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>;\n" +
     "${T}${T}${T}reset-names = \"bus\";\n",
     "${T}${T}${T}resets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>,\n" +
     "${T}${T}${T}${T} <&videocc VIDEO_CC_MVS0C_CLK_ARES>;\n" +
     "${T}${T}${T}reset-names = \"bus\", \"core\";\n",
     "DT: iris core reset")

if os.environ.get("ARP_SID_DT") == "I-know-it-hangs-boot":
    edit(DTS,
         "<&apps_smmu 0x2187 0x400>;",
         "<&apps_smmu 0x2187 0x400>,\n" +
         "${T}${T}${T}${T} <&apps_smmu 0x2184 0x400>;",
         "DT: iris non-pixel SID 0x2184 (BOOT HANG)")
else:
    print("SKIP DT: iris non-pixel SID 0x2184 -- it hangs the boot; see exp-arp-sid-mask.py")

# ---------------------------------------------------------- platform data ---
edit(os.path.join(IRIS, "iris_platform_vpu2.c"),
     "static const char * const sm8450_clk_reset_table[] = { \"bus\" };",
     "static const char * const sm8450_clk_reset_table[] = { \"bus\", \"core\" };",
     "platform data: bus+core resets")

# ----------------------------------------------------------- ARP mapping ----
edit(os.path.join(IRIS, "iris_buffer.c"),
     "#include <media/v4l2-event.h>\n",
     "#include <linux/iommu.h>\n"
     "#include <linux/mm.h>\n"
     "#include <media/v4l2-event.h>\n",
     "iris_buffer.c includes")

edit(os.path.join(IRIS, "iris_buffer.c"),
     "#define PIXELS_4K 4096\n",
     "#define PIXELS_4K 4096\n"
     "\n"
     "/* EXPERIMENT: start of the downstream non-pixel pool for the video core */\n"
     "#define IRIS_ARP_IOVA\t\t0x01000000\n",
     "iris_buffer.c ARP IOVA define")

edit(os.path.join(IRIS, "iris_buffer.c"),
     "#define IRIS_ARP_IOVA\t\t0x01000000\n",
     "#define IRIS_ARP_IOVA\t\t0x01000000\n"
     "\n"
     "static int iris_alloc_arp_buffer(struct iris_core *core, struct iris_buffer *buffer)\n"
     "{\n"
     "${T}struct iommu_domain *dom = iommu_get_domain_for_dev(core->dev);\n"
     "${T}unsigned int order = get_order(buffer->buffer_size);\n"
     "${T}struct page *page = alloc_pages(GFP_KERNEL | __GFP_ZERO, order);\n"
     "${T}int ret;\n"
     "\n"
     "${T}if (!page)\n"
     "${T}${T}return -ENOMEM;\n"
     "${T}if (!dom) {\n"
     "${T}${T}__free_pages(page, order);\n"
     "${T}${T}return -ENODEV;\n"
     "${T}}\n"
     "\n"
     "${T}ret = iommu_map(dom, IRIS_ARP_IOVA, page_to_phys(page),\n"
     "${T}${T}${T}  PAGE_ALIGN(buffer->buffer_size),\n"
     "${T}${T}${T}  IOMMU_READ | IOMMU_WRITE, GFP_KERNEL);\n"
     "${T}if (ret) {\n"
     "${T}${T}__free_pages(page, order);\n"
     "${T}${T}return ret;\n"
     "${T}}\n"
     "\n"
     "${T}buffer->kvaddr = page_address(page);\n"
     "${T}buffer->device_addr = IRIS_ARP_IOVA;\n"
     "\n"
     "${T}return 0;\n"
     "}\n",
     "iris_buffer.c: ARP alloc helper")

edit(os.path.join(IRIS, "iris_buffer.c"),
     "${T}struct iris_core *core = inst->core;\n" +
     "${T}struct iris_buffer *buffer;\n" +
     "\n" +
     "${T}if (!buffers->size)\n",
     "${T}struct iris_core *core = inst->core;\n" +
     "${T}struct iris_buffer *buffer;\n" +
     "${T}int ret;\n" +
     "\n" +
     "${T}if (!buffers->size)\n",
     "iris_buffer.c: create declares ret")

replace_span(os.path.join(IRIS, "iris_buffer.c"),
     "${T}buffer->kvaddr = dma_alloc_attrs(core->dev, buffer->buffer_size,",
     "${T}list_add_tail(&buffer->list, &buffers->list);",
     "${T}/*\n" +
     "${T} * EXPERIMENT: the VPP fetches the ARP stream through the non-pixel\n" +
     "${T} * context bank (SID 0x2184); map the buffer into the pool downstream\n" +
     "${T} * uses for it. Every other buffer keeps the normal allocation.\n" +
     "${T} */\n" +
     "${T}if (buffer_type == BUF_ARP) {\n" +
     "${T}${T}ret = iris_alloc_arp_buffer(core, buffer);\n" +
     "${T}${T}if (ret) {\n" +
     "${T}${T}${T}kfree(buffer);\n" +
     "${T}${T}${T}return ret;\n" +
     "${T}${T}}\n" +
     "${T}} else {\n" +
     "${T}${T}buffer->kvaddr = dma_alloc_attrs(core->dev, buffer->buffer_size,\n" +
     "${T}${T}${T}${T}${T}${T}${T} ${T}&buffer->device_addr,\n" +
     "${T}${T}${T}${T}${T}${T}${T} ${T}GFP_KERNEL, buffer->dma_attrs);\n" +
     "${T}${T}if (!buffer->kvaddr) {\n" +
     "${T}${T}${T}kfree(buffer);\n" +
     "${T}${T}${T}return -ENOMEM;\n" +
     "${T}${T}}\n" +
     "${T}}\n" +
     "\n" +
     "${T}list_add_tail(&buffer->list, &buffers->list);",
     "iris_buffer.c: ARP via fixed IOVA")

replace_span(os.path.join(IRIS, "iris_buffer.c"),
     "${T}dma_free_attrs(core->dev, buffer->buffer_size, buffer->kvaddr,",
     "buffer->dma_attrs);",
     "${T}if (buffer->type == BUF_ARP) {\n" +
     "${T}${T}iommu_unmap(iommu_get_domain_for_dev(core->dev), IRIS_ARP_IOVA,\n" +
     "${T}${T}${T}  PAGE_ALIGN(buffer->buffer_size));\n" +
     "${T}${T}free_pages((unsigned long)buffer->kvaddr,\n" +
     "${T}${T}${T}  get_order(buffer->buffer_size));\n" +
     "${T}} else {\n" +
     "${T}${T}dma_free_attrs(core->dev, buffer->buffer_size, buffer->kvaddr,\n" +
     "${T}${T}${T}${T} ${T} buffer->device_addr, buffer->dma_attrs);\n" +
     "${T}}",
     "iris_buffer.c: ARP unmap at destroy")

print("experiment applied")
