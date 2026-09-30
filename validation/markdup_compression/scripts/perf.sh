#!/bin/bash
# On-CPU profile (user + kernel stacks) of three variants, for flame graphs
set -e
apt-get -qq update >/dev/null && apt-get -qq install -y linux-tools-generic >/dev/null 2>&1
PERF=$(ls /usr/lib/linux-tools/*/perf | head -1); $PERF --version
cd /w; export PATH=/w/env/bin:$PATH
declare -A V=(
 [A_collate_bgzf]="samtools collate -O -u -f -@ 2 small_2M.bam | samtools fixmate -m -@ 2 - - | samtools sort -@ 2 -T tmpA - | samtools markdup -@ 2 - outA.bam"
 [B_collate_u]="samtools collate -O -u -f -@ 2 small_2M.bam | samtools fixmate -m -u -@ 2 - - | samtools sort -u -@ 2 -T tmpB - | samtools markdup -@ 2 - outB.bam"
 [D_none_u]="samtools fixmate -m -u -@ 2 small_2M.bam - | samtools sort -u -@ 2 -T tmpD - | samtools markdup -@ 2 - outD.bam"
)
for v in A_collate_bgzf B_collate_u D_none_u; do
  $PERF record -q -F 499 -g -o perf.$v.data -- bash -c "set -o pipefail; ${V[$v]}" 2>/dev/null
  $PERF script -i perf.$v.data > perf.$v.txt 2>/dev/null
  echo "$v $(wc -l < perf.$v.txt) lines"
done
