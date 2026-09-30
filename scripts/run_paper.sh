#!/usr/bin/env bash
# The paper's run: `make paper` pinned to one NUMA node, with the load on that
# node's CPUs and on the whole host logged for the whole run.
#
#   scripts/run_paper.sh [MAKE_ARGS...]        e.g. DENET_BIN_DIR=... CONDA_RUN=...
#   NUMA_NODE=3 scripts/run_paper.sh ...       node to pin to (default 3)
#
# Writes START (start, load, node, commit; then end and exit status), paper.log,
# load_node.txt and load_host.txt (mpstat every 10 s). Pinning is not a
# reservation: other users' jobs can still run on the node, hence the logs.
set -u
cd "$(dirname "$0")/.."
node=${NUMA_NODE:-3}
cpus=$(numactl --hardware | awk -v n="$node" '$1=="node" && $2==n && $3=="cpus:" {$1=$2=$3=""; print}' | xargs | tr ' ' ',')
[[ -n "$cpus" ]] || { echo "NUMA node $node not found (numactl --hardware)" >&2; exit 1; }

echo "started $(date '+%F %T'); load $(cut -d' ' -f1-3 /proc/loadavg); numactl --cpunodebind=$node --membind=$node (cpus $cpus); commit $(git rev-parse --short HEAD 2>/dev/null)" > START
mpstat -P "$cpus" 10 > load_node.txt 2>&1 & pn=$!
mpstat 10 > load_host.txt 2>&1 & ph=$!
numactl --cpunodebind="$node" --membind="$node" make paper "$@" > paper.log 2>&1
rc=$?
kill "$pn" "$ph"
echo "finished $(date '+%F %T'); exit $rc" >> START
exit "$rc"
