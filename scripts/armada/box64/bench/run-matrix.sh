#!/bin/bash
# Reproduce the measurements behind box64.box64rc.
#
# Needs the x86-64 cross compiler (aarch64 host):
#   dnf install gcc-x86_64-linux-gnu binutils-x86_64-linux-gnu
#
# Both workloads are freestanding (-nostdlib, raw syscalls), so nothing but
# dynarec-generated code is timed. Runs each setting ITER times and reports the
# median, one setting per row so the numbers can be attributed.
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-/var/tmp/box64-bench}
ITER=${ITER:-5}
CC=${CC:-x86_64-linux-gnu-gcc}
BOX64=${BOX64:-/usr/bin/box64}
CFLAGS="-O2 -ffreestanding -nostdlib -static -fno-stack-protector -fno-pie -no-pie"

mkdir -p "$WORK"
command -v "$CC" >/dev/null || {
    echo "missing $CC: dnf install gcc-x86_64-linux-gnu binutils-x86_64-linux-gnu" >&2
    exit 1
}
$CC $CFLAGS -o "$WORK/bench_st" "$HERE/bench_fs.c" || exit 1
$CC $CFLAGS -o "$WORK/bench_mt" "$HERE/bench_fs_mt.c" || exit 1

RCDIR=$WORK/rc
mkdir -p "$RCDIR"
# A DynaCache would serve blocks compiled under a previous setting and hide the
# difference being measured.
export BOX64_DYNACACHE=0
export BOX64_NOBANNER=1

section() {
    local f="$1"
    shift
    { echo '[*]'; printf '%s\n' "$@"; } >"$f"
}

median() {
    sort -n | awk '{ a[NR] = $1 } END { printf "%d", a[int((NR + 1) / 2)] }'
}

timeit() {
    local rc="$1" bin="$2" t0 t1 i
    local out=()
    for i in $(seq 1 "$ITER"); do
        t0=$(date +%s%N)
        BOX64_RCFILE="$rc" "$BOX64" "$bin" >/dev/null 2>&1
        t1=$(date +%s%N)
        out+=($(((t1 - t0) / 1000)))
    done
    printf '%s\n' "${out[@]}" | median
}

ms() {
    awk -v v="$1" 'BEGIN { printf "%.1f", v / 1000 }'
}

report() {
    local label="$1" st mt
    st=$(timeit "$RCDIR/$label.rc" "$WORK/bench_st")
    mt=$(timeit "$RCDIR/$label.rc" "$WORK/bench_mt")
    printf '%-15s single=%7s ms   atomic=%7s ms\n' "$label" "$(ms "$st")" "$(ms "$mt")"
}

S=(BOX64_DYNAREC_STRONGMEM=1)
section "$RCDIR/base.rc" "${S[@]}"
section "$RCDIR/strongmem0.rc" BOX64_DYNAREC_STRONGMEM=0
section "$RCDIR/strongmem2.rc" BOX64_DYNAREC_STRONGMEM=2
section "$RCDIR/forward1024.rc" "${S[@]}" BOX64_DYNAREC_FORWARD=1024
section "$RCDIR/safeflags0.rc" "${S[@]}" BOX64_DYNAREC_SAFEFLAGS=0
section "$RCDIR/bigblock3.rc" "${S[@]}" BOX64_DYNAREC_BIGBLOCK=3
section "$RCDIR/sep2.rc" "${S[@]}" BOX64_DYNAREC_SEP=2
section "$RCDIR/aligned1.rc" "${S[@]}" BOX64_DYNAREC_ALIGNED_ATOMICS=1
section "$RCDIR/weakbarrier2.rc" "${S[@]}" BOX64_DYNAREC_WEAKBARRIER=2
section "$RCDIR/pause1.rc" "${S[@]}" BOX64_DYNAREC_PAUSE=1
section "$RCDIR/shipped.rc" "${S[@]}" BOX64_DYNAREC_FORWARD=1024 \
    BOX64_DYNAREC_SAFEFLAGS=0 BOX64_DYNAREC_PAUSE=1

echo "$("$BOX64" --version 2>&1 | sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p' | head -1), ${ITER} runs per cell, median"
for label in ${ORDER:-base strongmem0 strongmem2 forward1024 safeflags0 bigblock3 sep2 aligned1 weakbarrier2 pause1 shipped}; do
    report "$label"
done
echo
echo "game-level check (window time, cold cache): see the repository log"
echo "  BOX64_RCFILE=<file> <steam tool> waitforexitandrun -- <game binary>"