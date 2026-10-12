// SPDX-License-Identifier: GPL-2.0
/*
 * iova_stress.c - hammer IOVA allocations to expose 32-bit exhaustion
 *
 * Reproducer for the AMD NBIO 7.7/7.11 "enhanced atomics" issue
 * (upstream commit 4fde44822512, "x86/PCI: Disable enhanced atomics
 * on AMD NBIO 7.7 and 7.11").
 *
 * On affected systems the NBIO enables "enhanced atomics", which
 * repurposes the upper 5 bits of DMA addresses. Any 64-bit DMA can
 * then be corrupted -- not just atomic operations. The corruption
 * only bites once IOVA allocations spill past 32 bits, which is why
 * Mario Limonciello's reproducer recipe is: "do some actions that
 * will cause a lot of IOVA allocations. Once you exhaust 32 bit,
 * you'll hit it."
 *
 * This module does exactly that: it performs a large number of DMA
 * mappings through the DMA API and reports when mappings start
 * landing above 32 bits. That is the exhaustion signal -- on an
 * affected, unpatched system it is the window where corruption
 * becomes possible.
 *
 * WARNING: deliberately exhausting IOVA space can destabilize the
 * machine -- other drivers' DMA mappings can start failing while
 * this module is loaded. Run only on expendable test systems or
 * VMs, never on a machine you care about.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>

#define DRV_NAME "iova_stress"

static unsigned long count = 100000;
module_param(count, ulong, 0444);
MODULE_PARM_DESC(count, "number of DMA mappings to perform");

static unsigned long alloc_size = 4096;
module_param(alloc_size, ulong, 0444);
MODULE_PARM_DESC(alloc_size, "bytes per mapping (rounded up to a page multiple)");

static struct platform_device *pdev;
static dma_addr_t *dma_addrs;
static struct page **pages;
static unsigned int order;
static unsigned long map_size;
static unsigned long mapped;

static int __init iova_stress_init(void)
{
	struct device *dev;
	unsigned long i;
	dma_addr_t dma, max_addr = 0;
	bool saw_high = false;
	int ret;

	pr_warn("%s: WARNING: this module deliberately exhausts IOVA space and can destabilize the system. Run only on expendable test machines or VMs.\n",
		DRV_NAME);

	pdev = platform_device_register_simple(DRV_NAME, -1, NULL, 0);
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);
	dev = &pdev->dev;

	/* Ask for a 64-bit mask so we can watch allocations spill past 32 bits */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (ret) {
		dev_warn(dev, "64-bit DMA mask not supported, falling back to 32-bit\n");
		ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
		if (ret)
			goto err_unregister;
	}

	order = get_order(alloc_size);
	map_size = PAGE_SIZE << order;

	dma_addrs = vmalloc(count * sizeof(*dma_addrs));
	pages = vmalloc(count * sizeof(*pages));
	if (!dma_addrs || !pages) {
		ret = -ENOMEM;
		goto err_free;
	}

	for (i = 0; i < count; i++) {
		struct page *pg = alloc_pages(GFP_KERNEL, order);

		if (!pg)
			break;
		dma = dma_map_page(dev, pg, 0, map_size, DMA_BIDIRECTIONAL);
		if (dma_mapping_error(dev, dma)) {
			__free_pages(pg, order);
			dev_warn(dev, "mapping %lu failed -- IOVA space exhausted?\n", i);
			break;
		}
		pages[mapped] = pg;
		dma_addrs[mapped] = dma;
		mapped++;

		if (dma > max_addr)
			max_addr = dma;
		if (!saw_high && dma > 0xFFFFFFFFULL) {
			saw_high = true;
			pr_warn("%s: mapping %lu landed above 32 bits (dma_addr=%pad) -- 32-bit IOVA space exhausted\n",
				DRV_NAME, i, &dma);
		}
		if ((i & 0xFFFF) == 0)
			pr_info("%s: %lu mappings done, max dma_addr=%pad\n",
				DRV_NAME, i, &max_addr);
	}

	pr_info("%s: done: %lu/%lu mappings, max dma_addr=%pad, above_32bit=%s\n",
		DRV_NAME, mapped, count, &max_addr, saw_high ? "yes" : "no");
	return 0;

err_free:
	vfree(dma_addrs);
	vfree(pages);
err_unregister:
	platform_device_unregister(pdev);
	return ret;
}

static void __exit iova_stress_exit(void)
{
	struct device *dev = &pdev->dev;
	unsigned long i;

	for (i = 0; i < mapped; i++) {
		dma_unmap_page(dev, dma_addrs[i], map_size, DMA_BIDIRECTIONAL);
		__free_pages(pages[i], order);
	}
	vfree(dma_addrs);
	vfree(pages);
	platform_device_unregister(pdev);
	pr_info("%s: unloaded, %lu mappings released\n", DRV_NAME, mapped);
}

module_init(iova_stress_init);
module_exit(iova_stress_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Sai Bontha");
MODULE_DESCRIPTION("IOVA allocation stress test - reproducer for the AMD NBIO enhanced-atomics DMA corruption issue");
