# nbio-enhanced-atomics-repro

A public reproducer for the AMD NBIO 7.7/7.11 "enhanced atomics" DMA corruption issue.

Upstream fix: [`4fde44822512`](https://git.kernel.org/linus/4fde44822512) ("x86/PCI: Disable enhanced atomics on AMD NBIO 7.7 and 7.11")
Discussion: [lore.kernel.org](https://lore.kernel.org/all/20260908190600.226485-2-mario.limonciello@amd.com/t/#u)

## The issue

On AMD NBIO 7.7 and 7.11, a feature called **enhanced atomics** repurposes the upper 5 bits of DMA addresses. It should not be enabled on these systems. When it is, **any 64-bit DMA can be corrupted** — not just atomic operations. A poisoned completion can surface far from the triggering operation, which from the storage side looks exactly like a drive firmware bug: the scary kind of failure that shows up three operations later and misdirects the whole debug effort.

The corruption only bites once IOVA allocations spill past 32 bits. That is why the reproducer recipe from Mario Limonciello (AMD) is:

> "do some actions that will cause a lot of IOVA allocations. Once you exhaust 32 bit, you'll hit it."

Storage hits it first because it allocates IOVA more quickly under stress than other devices.

The upstream quirk disables the feature and logs `enhanced atomics disabled` via `pci_info()` whenever it finds at least one affected device — that dmesg string is how you know a machine was affected.

## What's in this repo

- `iova_stress/` — Linux kernel module that performs a large number of DMA mappings through the DMA API and reports when mappings start landing above 32 bits. That is the exhaustion signal: the window where corruption becomes possible on an affected, unpatched system.
- `nvme_stress.sh` — read-only NVMe I/O pressure (fio, else nvme-cli, else dd) to create the storage-side allocation churn Mario described. Pair it with the module for maximum pressure.
- `check_quirk.sh` — checks dmesg for the `enhanced atomics disabled` signature and prints the relevant PCI/NBIO device info. Tells you whether a machine was affected.

## Usage

```bash
# 1. Build the module (needs kernel headers for your target kernel)
cd iova_stress && make KDIR=/lib/modules/$(uname -r)/build

# 2. On the expendable test machine, load it and watch dmesg
sudo insmod iova_stress.ko count=200000
dmesg | tail -20

# 3. In parallel, hammer NVMe (read-only)
sudo ./nvme_stress.sh --jobs 8 --runtime 300

# 4. Afterwards, check whether the quirk fired
./check_quirk.sh

# 5. Unload when done
sudo rmmod iova_stress
```

Module parameters:

| param        | default  | meaning                                    |
|--------------|----------|--------------------------------------------|
| `count`      | 100000   | number of DMA mappings to perform          |
| `alloc_size` | 4096     | bytes per mapping (rounded up to pages)    |

## Safety

Read this before running anything here:

- **Run only on expendable test systems or VMs.** Deliberately exhausting IOVA space can destabilize a running machine — other drivers' DMA mappings can start failing while the module is loaded.
- `nvme_stress.sh` is **read-only by default** and never writes to the device, but heavy I/O plus IOVA pressure can still wedge an affected machine.
- Do not run the module on a production system, a laptop you care about, or any machine with unsaved work.

## Honest caveats

- This is a **reproducer, not a fix**. The kernel fix is already upstream (commit `4fde44822512`). There is nothing here for a patched kernel to do.
- **Not hardware-validated.** This was developed without access to affected AMD NBIO 7.7/7.11 hardware, so the exhaustion behavior is reasoned from the upstream discussion, not observed on a real affected part. If you have affected hardware and can validate (or refute) the reproducer, that feedback is welcome.
- The module was compile-tested only; it was never loaded on the development machine.
- AMD is separately working on converting their internal reproducer into an upstreamable kunit test. If that lands, prefer it — an in-tree test beats an out-of-tree module.

## References

- Upstream commit: https://git.kernel.org/linus/4fde44822512
- Lore thread: https://lore.kernel.org/all/20260908190600.226485-2-mario.limonciello@amd.com/t/#u
- Thanks to Bjorn Helgaas and Mario Limonciello for the public technical discussion this reproducer is based on.

## License

MIT — see [LICENSE](LICENSE).
