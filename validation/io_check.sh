#!/usr/bin/env bash
# Independent check of per-process disk writes for the markdup pipeline.
# samtools sort keeps its temporary spill files until the final merge, so the
# largest size of each sort's temp directory (polled every 50 ms) is the bytes
# that sort wrote; the output file's size is what markdup wrote. Compare with
# the per-process disk_write_bytes in denet's JSONL for the same rule.
#
# usage: validation/io_check.sh results_denet/results/aligned_unsorted.bam [threads]
# needs samtools on PATH (e.g. the rule environment)
set -euo pipefail
in=$1; t=${2:-2}
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
mkdir -p "$w/name_sort" "$w/coord_sort"
( samtools sort -n -@ "$t" -T "$w/name_sort/x" "$in" \
  | samtools fixmate -m -@ "$t" - - \
  | samtools sort -@ "$t" -T "$w/coord_sort/x" - \
  | samtools markdup -@ "$t" - "$w/out.bam" ) 2>/dev/null &
pid=$!
max_n=0; max_c=0
while kill -0 "$pid" 2>/dev/null; do
  n=$(du -sb "$w/name_sort" | cut -f1); c=$(du -sb "$w/coord_sort" | cut -f1)
  (( n > max_n )) && max_n=$n; (( c > max_c )) && max_c=$c
  sleep 0.05
done
wait "$pid"
mib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }
out=$(stat -c %s "$w/out.bam")
echo "name sort, max temp dir:  $(mib "$max_n") MiB"
echo "coord sort, max temp dir: $(mib "$max_c") MiB"
echo "markdup output file:      $(mib "$out") MiB"
echo "total:                    $(mib $(( max_n + max_c + out ))) MiB"
