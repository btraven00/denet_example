#!/usr/bin/env bash
# Does the duplicate-marking peak come from two sort buffers held at once?
# Runs the original rule (sort -n | fixmate | sort | markdup) with each sort's
# memory limit set independently, under denet, and records the tree's peak RSS
# and each sort's own peak. Two coexisting buffers predict a peak that tracks
# the SUM of the two limits; a single accumulating stage, their MAXIMUM.
#
#   validation/markdup_buffers/run.sh IN.bam OUT_DIR [REPEATS]
# Needs samtools and denet on PATH. Limits are per thread; 2 threads per stage,
# as in the paper. The input must be large enough for both sorts to spill.
set -euo pipefail
bam=$1 out=$2 reps=${3:-2}
mkdir -p "$out"
for r in $(seq "$reps"); do
  for mn in 128M 256M 512M; do
    for mc in 128M 256M 512M; do
      t="$out/n${mn}_c${mc}_r$r"
      denet -q -i 50 -m 500 -o "$t.jsonl" run -- bash -euo pipefail -c "
        samtools sort -n -@ 2 -m $mn -T $t.n $bam \
        | samtools fixmate -m -@ 2 - - \
        | samtools sort -@ 2 -m $mc -T $t.c - \
        | samtools markdup -@ 2 - $t.bam" 2>/dev/null
      rm -f "$t.bam"
    done
  done
done
python3 "$(dirname "$0")/summarise.py" "$out"
