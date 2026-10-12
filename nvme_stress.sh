#!/bin/bash
#
# nvme_stress.sh - storage-side I/O pressure for the NBIO enhanced-atomics reproducer
#
# Why this exists: per Mario Limonciello, the AMD NBIO "enhanced atomics"
# corruption bites once 32-bit IOVA space is exhausted, and "storage
# allocates IOVA more quickly under stress" -- so hammering NVMe queue
# pairs is the fastest way to reach the exhaustion window from userspace.
# Pair this with the iova_stress kernel module for maximum pressure.
#
# SAFETY: this script is READ-ONLY by default. It never writes to the
# device. Run only on expendable test systems -- heavy I/O plus IOVA
# pressure can wedge an affected machine.
#
# Usage: ./nvme_stress.sh [--device /dev/nvme0n1] [--jobs 8] [--runtime 300]

set -u

DEVICE=""
JOBS=8
RUNTIME=300

while [ $# -gt 0 ]; do
    case "$1" in
        --device)  DEVICE="$2"; shift 2 ;;
        --jobs)    JOBS="$2";   shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            echo "Usage: $0 [--device /dev/nvme0n1] [--jobs 8] [--runtime 300]"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Pick a namespace if the user didn't name one.
if [ -z "$DEVICE" ]; then
    for cand in /dev/nvme*n1; do
        if [ -b "$cand" ]; then DEVICE="$cand"; break; fi
    done
fi
if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
    echo "no NVMe namespace found (tried /dev/nvme*n1). Pass --device explicitly." >&2
    exit 1
fi

echo "nvme_stress: read-only I/O against $DEVICE, jobs=$JOBS, runtime=${RUNTIME}s"
echo "nvme_stress: press Ctrl-C to stop early"
echo

# Best case: fio with parallel random reads -- this is what actually
# keeps many queue pairs busy and churns DMA mappings.
if command -v fio >/dev/null 2>&1; then
    echo "nvme_stress: using fio"
    exec fio --name=iova-read --filename="$DEVICE" --rw=randread --bs=4k \
        --numjobs="$JOBS" --iodepth=64 --direct=1 --group_reporting \
        --runtime="$RUNTIME" --time_based
fi

# Fallback: nvme-cli reads in parallel. Each nvme read maps a buffer,
# so N parallel loops keep the IOVA allocator busy.
if command -v nvme >/dev/null 2>&1; then
    echo "nvme_stress: fio not found, using nvme-cli reads (install fio for heavier pressure)"
    NSIZE=$(nvme id-ns "$DEVICE" 2>/dev/null | grep -o 'nsze.*: *[0-9]*' | grep -o '[0-9]*' | head -1)
    : "${NSIZE:=2097152}"
    # stay inside the first 8 GiB so we never run off the namespace
    MAXLBA=$(( NSIZE < 16777216 ? NSIZE - 256 : 16777216 ))
    worker() {
        local end=$(( $(date +%s) + RUNTIME ))
        while [ "$(date +%s)" -lt "$end" ]; do
            # random 4 KiB-aligned LBA inside the safe range
            LBA=$(( RANDOM * RANDOM % MAXLBA ))
            nvme read "$DEVICE" --start-block="$LBA" --block-count=8 \
                --data-size=4096 >/dev/null 2>&1 || true
        done
    }
    for _ in $(seq 1 "$JOBS"); do worker & done
    wait
    echo "nvme_stress: done"
    exit 0
fi

# Last resort: parallel dd reads with direct I/O.
echo "nvme_stress: fio and nvme-cli not found, using dd (weakest pressure)"
end=$(( $(date +%s) + RUNTIME ))
for _ in $(seq 1 "$JOBS"); do
    (
        while [ "$(date +%s)" -lt "$end" ]; do
            dd if="$DEVICE" of=/dev/null bs=4k count=256 iflag=direct status=none 2>/dev/null || true
        done
    ) &
done
wait
echo "nvme_stress: done"
