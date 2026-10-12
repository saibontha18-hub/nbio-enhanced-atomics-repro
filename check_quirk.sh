#!/bin/bash
#
# check_quirk.sh - check whether this system was affected by the AMD NBIO
# "enhanced atomics" issue.
#
# Background: on AMD NBIO 7.7/7.11 the "enhanced atomics" feature repurposes
# the upper 5 bits of DMA addresses, corrupting any 64-bit DMA once IOVA
# allocations spill past 32 bits. Upstream commit 4fde44822512
# ("x86/PCI: Disable enhanced atomics on AMD NBIO 7.7 and 7.11") disables
# the feature, and the kernel logs:
#
#     pci_info(host_bridge, "enhanced atomics disabled");
#
# ...whenever it finds at least one affected device. So: if that string is
# in dmesg, this machine was affected (and is now protected by the quirk).
# If it is absent, the machine was not affected -- or it runs a kernel
# older than the fix.

set -u

echo "=== kernel ==="
uname -r
echo

echo "=== quirk signature in dmesg ==="
if dmesg 2>/dev/null | grep -q "enhanced atomics disabled"; then
    echo "FOUND: this system was affected by the enhanced-atomics issue."
    echo "The upstream quirk disabled the feature on at least one device."
    dmesg 2>/dev/null | grep "enhanced atomics disabled" | head -5
else
    echo "not found: no affected device detected (or kernel predates the fix)."
fi
echo

echo "=== AMD host bridges / NBIO devices ==="
if command -v lspci >/dev/null 2>&1; then
    # NBIO root ports and host bridges are where the quirk applies
    lspci -nn 2>/dev/null | grep -iE "AMD.*(host bridge|PCI bridge|NBIO)" | head -20
    echo "(full list: lspci -nn | grep -i amd)"
else
    echo "lspci not installed; install pciutils for device details."
fi
echo

echo "=== IOMMU / DMA domain info ==="
if [ -d /sys/kernel/iommu_groups ]; then
    echo "iommu_groups present: $(ls /sys/kernel/iommu_groups | wc -l) groups"
else
    echo "no IOMMU groups visible (IOMMU may be disabled or unsupported here)"
fi
