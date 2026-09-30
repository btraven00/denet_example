#!/bin/bash
# 2x2: grouping step (collate -f / none) x pipes (compressed / -u); 2 threads per stage as in the paper
set -e
cd /w; export PATH=/w/env/bin:$PATH
declare -A V=(
 [A_collate_bgzf]="samtools collate -O -u -f -@ 2 small_2M.bam | samtools fixmate -m -@ 2 - - | samtools sort -@ 2 -T tmpA - | samtools markdup -@ 2 - outA.bam"
 [B_collate_u]="samtools collate -O -u -f -@ 2 small_2M.bam | samtools fixmate -m -u -@ 2 - - | samtools sort -u -@ 2 -T tmpB - | samtools markdup -@ 2 - outB.bam"
 [C_none_bgzf]="samtools fixmate -m -@ 2 small_2M.bam - | samtools sort -@ 2 -T tmpC - | samtools markdup -@ 2 - outC.bam"
 [D_none_u]="samtools fixmate -m -u -@ 2 small_2M.bam - | samtools sort -u -@ 2 -T tmpD - | samtools markdup -@ 2 - outD.bam"
)
for rep in 1 2 3; do for v in A_collate_bgzf B_collate_u C_none_bgzf D_none_u; do
  ./denet -q -i 50 -m 500 --enable-ebpf -o $v.r$rep.jsonl run bash -c "set -o pipefail; ${V[$v]}" 2> $v.r$rep.log
  echo "$v r$rep done"
done; done
for v in A B C D; do samtools view -c -f 1024 out$v.bam; done
