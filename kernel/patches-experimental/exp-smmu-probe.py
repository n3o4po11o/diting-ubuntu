#!/usr/bin/env python3
"""EXPERIMENT probe tool for the apps SMMU stream match registers (applies on
top of exp-arp-sid-mask.py):

    echo "<sid>"            > /sys/module/qcom_iris/parameters/arp_smmu_write   # log the entry
    echo "<sid>:<reg>"     > ...                                                  # write it, read back
    echo "dump"            > ...                                                  # whole table + sCR0

A rejected write takes a synchronous external abort that kills only the
calling process, but it leaves the SMMU device's runtime PM lock held: one
rejected probe per boot. Loads with arp_sid_alias=0 arp_probe_only=1 to keep
sessions away. Usage: python3 exp-smmu-probe.py <kernel-src-dir>
"""
import sys
p = sys.argv[1] + "/drivers/media/platform/qcom/iris/iris_buffer.c"
s = open(p).read()
if "iris_smmu_dump" in s:
    print("already patched"); sys.exit(0)

def rep(old, new):
    global s
    assert s.count(old) == 1, (old[:60], s.count(old))
    s = s.replace(old, new)

anchor = "module_param(arp_sid_alias, bool, 0644);\n"
assert s.count(anchor) == 1
code = r'''
/*
 * EXPERIMENT probe tool for the apps SMMU stream match registers:
 *   echo "<sid>"        -> log the entry whose ID is sid
 *   echo "<sid>:<reg>"  -> write reg (hex) into it and read it back
 * The write runs in the caller's process: a rejected write (synchronous
 * external abort) kills only that process.
 */
static int iris_smmu_write_smr(u32 sid, u32 reg, bool write)
{
	struct device *smmu_dev;
	void __iomem *base;
	u32 cur, rd = 0;
	int idx, ret = -ENODEV;
	char buf[96];
	int len;

	smmu_dev = bus_find_device_by_name(&platform_bus_type, NULL,
					   "15000000.iommu");
	if (!smmu_dev)
		return -ENODEV;

	ret = pm_runtime_get_sync(smmu_dev);
	if (ret < 0 && ret != -EACCES) {
		put_device(smmu_dev);
		return ret;
	}

	ret = -ENODEV;
	base = ioremap(0x15000000, 0x10000);
	if (!base) {
		ret = -ENOMEM;
		goto out;
	}

	for (idx = 0; idx < 128; idx++) {
		cur = readl_relaxed(base + 0x800 + idx * 4);
		if ((cur & 0x7fff) == sid && ((cur >> 16) & 0x7fff) != 0x7fff)
			goto found;
	}
	len = scnprintf(buf, sizeof(buf), "no stream match entry for SID %#x\n", sid);
	goto unmap;

found:
	len = scnprintf(buf, sizeof(buf), "SMR[%d] SID %#x: %#x", idx, sid, cur);
	if (!write) {
		len += scnprintf(buf + len, sizeof(buf) - len, " (read only)\n");
		ret = 0;
		goto unmap;
	}
	pr_info("iris-smmu-probe: about to write %#x\n", reg);
	writel_relaxed(reg, base + 0x800 + idx * 4);
	rd = readl_relaxed(base + 0x800 + idx * 4);
	len += scnprintf(buf + len, sizeof(buf) - len, " -> wrote %#x, read back %#x\n",
			 reg, rd);
	ret = (rd == reg) ? 0 : -EIO;

unmap:
	iounmap(base);
out:
	pm_runtime_put(smmu_dev);
	put_device(smmu_dev);
	pr_info("iris-smmu-probe: %s", buf);
	return ret;
}

static int iris_arp_smmu_set(const char *val, const struct kernel_param *kp)
{
	u32 sid, reg;
	int n;

	n = sscanf(val, "%i:%i", &sid, &reg);
	if (n < 1)
		return -EINVAL;

	return iris_smmu_write_smr(sid, reg, n == 2);
}

static int iris_arp_smmu_get(char *buf, const struct kernel_param *kp)
{
	return scnprintf(buf, PAGE_SIZE, "\"<sid>\" reads, \"<sid>:<reg>\" writes the apps SMMU stream match entry\n");
}

static const struct kernel_param_ops iris_arp_smmu_ops = {
	.set = iris_arp_smmu_set,
	.get = iris_arp_smmu_get,
};
module_param_cb(arp_smmu_write, &iris_arp_smmu_ops, NULL, 0600);
'''
s = s.replace(anchor, anchor + code, 1)
anchor = "static int iris_arp_smmu_set(const char *val, const struct kernel_param *kp)\n{\n"
assert s.count(anchor) == 1
dump = r'''static int iris_smmu_dump(void)
{
	struct device *smmu_dev;
	void __iomem *base;
	char buf[80];
	int n, len, ret;

	smmu_dev = bus_find_device_by_name(&platform_bus_type, NULL,
					   "15000000.iommu");
	if (!smmu_dev)
		return -ENODEV;

	ret = pm_runtime_get_sync(smmu_dev);
	if (ret < 0 && ret != -EACCES) {
		put_device(smmu_dev);
		return ret;
	}

	ret = -ENOMEM;
	base = ioremap(0x15000000, 0x10000);
	if (!base)
		goto out;

	for (n = 0; n < 113; n++) {
		u32 smr = readl_relaxed(base + 0x800 + n * 4);
		u32 s2cr = readl_relaxed(base + 0xc00 + n * 4);

		if (!smr && !s2cr)
			continue;
		len = scnprintf(buf, sizeof(buf), "SMR[%2d] = %#010x", n, smr);
		if (smr & BIT(31))
			len += scnprintf(buf + len, sizeof(buf) - len,
					 " valid ID %#x mask %#x", smr & 0x7fff, (smr >> 16) & 0x7fff);
		len += scnprintf(buf + len, sizeof(buf) - len, "  S2CR = %#010x\n", s2cr);
		pr_info("iris-smmu-probe: %s", buf);
	}
	pr_info("iris-smmu-probe: sCR0 = %#010x IDR0 = %#010x\n",
		readl_relaxed(base), readl_relaxed(base + 0x20));
	iounmap(base);
	ret = 0;
out:
	pm_runtime_put(smmu_dev);
	put_device(smmu_dev);
	return ret;
}

'''
s = s.replace(anchor, dump + anchor, 1)
old = "\tn = sscanf(val, \"%i:%i\", &sid, &reg);\n\tif (n < 1)\n\t\treturn -EINVAL;\n"
assert s.count(old) == 1
s = s.replace(old, "\tif (sysfs_streq(val, \"dump\"))\n\t\treturn iris_smmu_dump();\n\n" + old, 1)
open(p, "w").write(s)
print("probe tool applied")
