#!/usr/bin/env bash
# Are the upstream stages *blocked* while the coordinate sort spills?
# Runs the original duplicate-marking pipeline (sort -n | fixmate | sort |
# markdup) under denet with eBPF, so each process's off-CPU time is recorded,
# and compares it inside and outside the coordinate sort's spill windows.
#
#   validation/markdup_stalls/run.sh IN.bam OUT_DIR [REPEATS] [SORT_MEM]
# Needs samtools on PATH and a denet with eBPF and the capabilities (or root).
# SORT_MEM (per thread, default 256M) is set low so that a small input spills.
set -euo pipefail
bam=$1 out=$2 reps=${3:-3} mem=${4:-256M}
mkdir -p "$out"
denet --version > "$out/denet_version.txt"
denet --write-env -q -o "$out/env.jsonl" run -- true   # host record
for r in $(seq "$reps"); do
  t="$out/r$r"
  # fixed 50 ms sampling: the spills last about a second at this size
  denet --enable-ebpf -q -i 50 -m 50 -o "$t.jsonl" run -- bash -euo pipefail -c "
    samtools sort -n -@ 2 -m $mem -T $t.n $bam \
    | samtools fixmate -m -@ 2 - - \
    | samtools sort -@ 2 -m $mem -T $t.c - \
    | samtools markdup -@ 2 - $t.bam" 2>/dev/null
  rm -f "$t.bam"
done
python3 "$(dirname "$0")/analyse.py" "$out"/r*.jsonl
